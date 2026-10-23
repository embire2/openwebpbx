# SPDX-License-Identifier: AGPL-3.0-or-later
# Collect a source candidate on a disposable runner; never sign or publish it.
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or !$env:RUNNER_TEMP -or $env:PHONE_SOURCE_REF -cnotmatch '^[a-f0-9]{40}$'){throw 'Use the disposable hosted Windows source job with an exact reviewed commit.'}
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
$destination=[IO.Path]::GetFullPath($Output)
if(!$destination.StartsWith(($temp+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $destination)){throw 'Use a new output strictly below RUNNER_TEMP.'}
$parent=Split-Path $destination -Parent
while($parent){
 if(Test-Path -LiteralPath $parent){$item=Get-Item -LiteralPath $parent -Force;if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Output ancestry must be ordinary directories.'}}
 if([string]::Equals($parent,$temp,[StringComparison]::OrdinalIgnoreCase)){break};$parent=Split-Path $parent -Parent
}
if(!$parent){throw 'Output ancestry did not reach RUNNER_TEMP.'}
$source=(git rev-parse HEAD).Trim();if($LASTEXITCODE -or $source -cne $env:PHONE_SOURCE_REF){throw 'The checked-out source differs.'}
$collector=Join-Path $PSScriptRoot 'Collect-CorrespondingSource.ps1'
$sourceLock=Join-Path (Split-Path $PSScriptRoot -Parent) 'native/source-lock.json'
if((Get-FileHash -LiteralPath $collector -Algorithm SHA256).Hash.ToLowerInvariant() -cne '766c853b1d793abaf092e38203ecb571ae74620b9caded16eacfe2270a63753f' -or (Get-FileHash -LiteralPath $sourceLock -Algorithm SHA256).Hash.ToLowerInvariant() -cne '3e7095aceffd314638606da03caed1867c3546314dc2898d43dbc2ab8241f0ac'){throw 'The reviewed source collector inputs differ.'}
$evidence=Join-Path $destination 'evidence';$packet=Join-Path $destination 'packet'
$null=New-Item -ItemType Directory -Path $evidence
$report=[ordered]@{schema=1;component='windows-free-phone-source';version='1.0.0';source_commit=$source;state='running';sdk_sha256='9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297';source_lock_sha256='3e7095aceffd314638606da03caed1867c3546314dc2898d43dbc2ab8241f0ac';binary_source_mapping_verified=$false;source_sdk_rebuild_qualified=$false;actual_calling_tested=$false;hardware_media_tested=$false;store_accepted=$false}
$process=$null;$download=$null;$response=$null;$http=$null;$handler=$null;$failed=$false
function WriteSourceCiJson([string]$Path,$Value){
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 8)+"`n")
 if($bytes.Length -gt 64KB){throw 'The closed source report exceeds its bound.'}
 $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function AssertSourceCiResult($Result,[string]$Commit,[string]$LockSha){
 $fields=@('schema','state','client_commit','source_lock_sha256','archive_filename','archive_bytes','archive_sha256','manifest_sha256','repositories','files','source_bytes','licence_files','binary_source_mapping_verified','source_sdk_rebuild_qualified','store_accepted')
 if($Result -isnot [pscustomobject] -or (Compare-Object @($Result.PSObject.Properties.Name|Sort-Object -CaseSensitive) @($fields|Sort-Object -CaseSensitive) -CaseSensitive)){throw 'The source qualification field set differs.'}
 foreach($field in @('schema','archive_bytes','repositories','files','source_bytes','licence_files')){if($Result.$field -isnot [int] -and $Result.$field -isnot [long]){throw 'The source qualification integer type differs.'}}
 foreach($field in @('state','client_commit','source_lock_sha256','archive_filename','archive_sha256','manifest_sha256')){if($Result.$field -isnot [string]){throw 'The source qualification string type differs.'}}
 if($Result.schema -ne 1 -or $Result.state -cne 'collected_source_candidate_not_binary_correspondence' -or $Result.client_commit -cne $Commit -or $Result.source_lock_sha256 -cne $LockSha -or $Result.archive_filename -cne 'openwebpbx-free-phone-1.0.0-source-candidate.zip' -or $Result.archive_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Result.manifest_sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'The source qualification identity differs.'}
 foreach($flag in @('binary_source_mapping_verified','source_sdk_rebuild_qualified','store_accepted')){if($Result.$flag -isnot [bool] -or $Result.$flag){throw 'The source qualification scope differs.'}}
 if($Result.archive_bytes -lt 1 -or $Result.archive_bytes -gt 2147483647 -or $Result.repositories -lt 32 -or $Result.repositories -gt 128 -or $Result.files -lt 1 -or $Result.files -gt 250000 -or $Result.source_bytes -lt 1 -or $Result.source_bytes -gt 1610612736 -or $Result.licence_files -lt 1 -or $Result.licence_files -gt $Result.files){throw 'The source qualification counts differ.'}
}
function AssertSourceCiManifest([string]$Archive,[string]$ExpectedSha,[long]$ExpectedFiles){
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
 try{
  if($zip.Entries.Count -ne $ExpectedFiles+1){throw 'The source archive entry count differs.'}
  $entries=@($zip.Entries|Where-Object {$_.FullName -ceq 'source-manifest.json'})
  if($entries.Count -ne 1 -or $entries[0].ExternalAttributes -ne 0 -or $entries[0].Length -lt 2 -or $entries[0].Length -gt 128MB){throw 'An ordinary bounded unique source manifest is required.'}
  $input=$entries[0].Open();$hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
  try{
   $buffer=[byte[]]::new(131072);$count=0L
   while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){$count+=$read;if($count -gt 128MB){throw 'The source manifest exceeds its bound.'};$hash.AppendData($buffer,0,$read)}
   if($count -ne $entries[0].Length -or [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant() -cne $ExpectedSha){throw 'The inner source manifest digest differs.'}
  }finally{$input.Dispose();$hash.Dispose()}
 }finally{$zip.Dispose()}
}
try{
 if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($temp))).AvailableFreeSpace -lt 13GB){throw 'Insufficient disposable runner capacity.'}
 $archive=Join-Path $temp ('phone-source-sdk-'+[Guid]::NewGuid().ToString('N')+'.zip')
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
 $http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[Threading.Timeout]::InfiniteTimeSpan
 $deadline=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(20))
 try{
  $uri=[Uri]'https://download.linphone.org/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip'
  for($redirect=0;$redirect -le 3;$redirect++){
   if($uri.Scheme -cne 'https' -or $uri.Host -cne 'download.linphone.org' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment){throw 'The SDK redirect left its fixed HTTPS origin.'}
   $response=$http.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult()
   if([int]$response.StatusCode -in 301,302,303,307,308){$location=$response.Headers.Location;if(!$location -or $redirect -eq 3){throw 'The bounded SDK redirect differs.'};$uri=[Uri]::new($uri,$location);$response.Dispose();$response=$null;continue}
   if([int]$response.StatusCode -ne 200){throw 'The official SDK download failed.'};break
  }
  if(!$response -or [int]$response.StatusCode -ne 200){throw 'The official SDK response is incomplete.'}
  if($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne 315960147){throw 'The SDK response length differs.'}
  $download=[IO.File]::Open($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $input=$response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
  try{
   $buffer=[byte[]]::new(131072);$count=0L
   while(($read=$input.ReadAsync($buffer,0,$buffer.Length,$deadline.Token).GetAwaiter().GetResult()) -gt 0){$count+=$read;if($count -gt 315960147){throw 'The SDK download exceeds its exact bound.'};$download.Write($buffer,0,$read)}
   $download.Flush($true)
  }finally{$input.Dispose();$download.Dispose();$download=$null}
 }finally{$deadline.Dispose()}
 if((Get-Item -LiteralPath $archive).Length -ne 315960147 -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $report.sdk_sha256){throw 'The complete official SDK input differs.'}
 $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$collector,'-Mode','Collect','-SdkArchive',$archive,'-Output',$packet)){$info.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$end=[DateTime]::UtcNow.AddMinutes(90)
 while(!$process.WaitForExit(1000)){if([DateTime]::UtcNow -gt $end){$process.Kill($true);$process.WaitForExit();throw 'The source collection exceeded its bounded deadline.'}}
 $closedOutput=$stdout.GetAwaiter().GetResult();$privateErrors=$stderr.GetAwaiter().GetResult();$report.collector_exit_code=[int]$process.ExitCode
 if($process.ExitCode -or $closedOutput.Length -gt 64KB -or $privateErrors.Length -gt 1MB -or $privateErrors.Length){throw 'The source collector did not complete cleanly.'}
 $items=@(Get-ChildItem -LiteralPath $packet -Force)
 $expected=@('openwebpbx-free-phone-1.0.0-source-candidate.zip','source-qualification.json','SHA256SUMS')
 if($items.Count -ne 3 -or @($items|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -cnotin $expected}).Count){throw 'The source packet scope differs.'}
 $qualification=Join-Path $packet 'source-qualification.json';$qualificationFile=Get-Item -LiteralPath $qualification
 if($qualificationFile.Length -gt 64KB){throw 'The source qualification exceeds its bound.'}
 $result=Get-Content -LiteralPath $qualification -Raw|ConvertFrom-Json
 AssertSourceCiResult $result $source $report.source_lock_sha256
 $zip=Get-Item -LiteralPath (Join-Path $packet $expected[0]);$zipHash=(Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 if($zip.Length -lt 1 -or $zip.Length -gt 2147483647 -or $zip.Length -ne $result.archive_bytes -or $zipHash -cne $result.archive_sha256){throw 'The source archive differs.'}
 AssertSourceCiManifest $zip.FullName $result.manifest_sha256 $result.files
 $sum=Get-Item -LiteralPath (Join-Path $packet 'SHA256SUMS');if($sum.Length -gt 256 -or [IO.File]::ReadAllText($sum.FullName) -cne ($zipHash+'  '+$expected[0]+"`n")){throw 'The source archive checksum record differs.'}
 Copy-Item -LiteralPath $qualification -Destination (Join-Path $evidence 'source-qualification.json')
 $report.archive_sha256=$zipHash;$report.archive_bytes=$zip.Length;$report.manifest_sha256=$result.manifest_sha256;$report.repositories=$result.repositories;$report.files=$result.files;$report.state='collected_candidate_only'
}catch{$failed=$true;$report.state='failed';$report.error_type=$_.Exception.GetType().Name;$report.source_line=$_.InvocationInfo.ScriptLineNumber}
finally{
 if($process){try{if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()}}finally{$process.Dispose()}}
 if($download){$download.Dispose()};if($response){$response.Dispose()};if($http){$http.Dispose()}elseif($handler){$handler.Dispose()}
 WriteSourceCiJson (Join-Path $evidence 'qualification.json') $report
}
if($failed){throw 'Source candidate collection failed; consult the closed qualification receipt.'}
