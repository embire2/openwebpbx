# SPDX-License-Identifier: AGPL-3.0-or-later
# Public, exact component input for a disposable native-client job.
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the disposable hosted Windows job may fetch this input.'}
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\');$Output=[IO.Path]::GetFullPath($Output)
if([IO.Path]::GetDirectoryName($Output) -ine $temp -or [IO.Path]::GetFileName($Output) -cnotmatch '^phone-package-sdk\.zip$' -or (Test-Path -LiteralPath $Output)){throw 'The SDK output must be a new fixed runner-temporary file.'}
for($parent=[IO.DirectoryInfo]::new($temp);$null -ne $parent;$parent=$parent.Parent){if(!$parent.Exists -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The SDK output ancestry must be ordinary.'}}
$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseDefaultCredentials=$false
$http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[Threading.Timeout]::InfiniteTimeSpan
$deadline=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(15));$response=$null;$outputFile=$null;$created=$false;$verified=$false;$primary=$null
try{
 $uri=[Uri]'https://download.linphone.org/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip'
 for($redirect=0;$redirect -le 3;$redirect++){
  if($uri.Scheme -cne 'https' -or $uri.Host -cne 'download.linphone.org' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip'){throw 'The exact public SDK destination differs.'}
  $response=$http.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult()
  if([int]$response.StatusCode -in 301,302,303,307,308){$next=$response.Headers.Location;if(!$next -or $redirect -eq 3){throw 'The SDK redirect bound was exceeded.'};$uri=[Uri]::new($uri,$next);$response.Dispose();$response=$null;continue}
  if([int]$response.StatusCode -ne 200){throw 'The pinned public SDK is unavailable.'};break
 }
 if(!$response -or [int]$response.StatusCode -ne 200 -or ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne 315960147)){throw 'The exact SDK response length differs.'}
 $outputFile=[IO.File]::Open($Output,'CreateNew','Write','None');$created=$true;$input=$response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
 try{$bytes=[byte[]]::new(131072);$total=0L;while(($n=$input.ReadAsync($bytes,0,$bytes.Length,$deadline.Token).GetAwaiter().GetResult()) -gt 0){$total+=$n;if($total -gt 315960147){throw 'The SDK input exceeds its exact bound.'};$outputFile.Write($bytes,0,$n)};$outputFile.Flush($true)}finally{$input.Dispose();$outputFile.Dispose();$outputFile=$null}
 if((Get-Item -LiteralPath $Output).Length -ne 315960147 -or (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant() -cne '9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297'){throw 'The complete official SDK bytes differ.'}
 $verified=$true
}catch{$primary=$_;throw}finally{
 if($outputFile){$outputFile.Dispose()};if($response){$response.Dispose()};$deadline.Dispose();$http.Dispose()
 if($created -and !$verified){try{Remove-Item -LiteralPath $Output -Force -ErrorAction Stop}catch{if($primary){try{$primary.Exception.Data['owned_partial_sdk_cleanup_failed']=$true}catch{}}else{throw}}}
}
