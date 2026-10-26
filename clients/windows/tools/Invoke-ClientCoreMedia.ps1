#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
# Called only with the current producer's fresh owned SDK and source-built DLL.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
      [Parameter(Mandatory)][string]$WorkRoot,
      [Parameter(Mandatory)][string]$SdkZip,
      [Parameter(Mandatory)][string]$WavProducer,
      [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$WavProducerSha256)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the disposable hosted Windows client composition is allowed.'}
if((Test-Path 'C:\OpenWebPBX') -or (Test-Path (Join-Path $env:ProgramData 'OpenWebPBX'))){throw 'An installed PBX is outside this composition.'}
foreach($name in @('Hash','PrivateDirectory','NoLinks','MediaGet')){
    $command=Get-Command $name -CommandType Function -ErrorAction Stop
    if(!$command.ScriptBlock.File -or [IO.Path]::GetFullPath($command.ScriptBlock.File) -ine (Join-Path $PSScriptRoot 'WavProducerPrimitives.ps1')){throw 'The original producer primitive context is required.'}
}
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\');$work=[IO.Path]::GetFullPath($WorkRoot)
if([IO.Path]::GetDirectoryName($work) -ine $temp -or [IO.Path]::GetFileName($work) -cnotmatch '^phone-wav-work-[a-f0-9]{32}$' -or [IO.Path]::GetFullPath($SdkZip) -ine (Join-Path $work 'sdk.zip') -or [IO.Path]::GetFullPath($WavProducer) -ine (Join-Path $work 'build/Release/libmsopenwebwav.dll')){throw 'Only the current producer-owned inputs are allowed.'}
NoLinks $work
if((Get-Item -LiteralPath $SdkZip).Length -ne 315960147 -or (Hash $SdkZip) -cne '9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297' -or (Hash $WavProducer) -cne $WavProducerSha256){throw 'The current source-built recorder/SDK differs.'}
$evidence=Join-Path $temp 'phone-core-media-evidence';PrivateDirectory $evidence

function CopyCoreEngineBody([IO.Stream]$BodyStream,[string]$Target,[long]$ExpectedBytes,[string]$ExpectedSha256,[Threading.CancellationToken]$Token){
    $output=[IO.File]::Open($Target,'CreateNew','Write','None')
    try{
        $buffer=[byte[]]::new(131072);$total=0L
        while(($read=$BodyStream.ReadAsync($buffer,0,$buffer.Length,$Token).GetAwaiter().GetResult()) -gt 0){
            $total+=$read;if($total -gt $ExpectedBytes){throw 'Pinned engine body exceeds its exact bound.'}
            $output.Write($buffer,0,$read)
        }
        $output.Flush($true)
    }finally{$output.Dispose()}
    if($total -ne $ExpectedBytes -or (Hash $Target) -cne $ExpectedSha256){throw 'The exact accepted engine archive differs.'}
}
function GetCoreEngine([string]$Target){
    if(!$env:MEDIA_ACTIONS_TOKEN){throw 'The read-only repository artifact token is required.'}
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false;$handler.UseDefaultCredentials=$false
    $api=[Net.Http.HttpClient]::new($handler);$api.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $storage=$null;$storageHandler=$null;$response=$null;$stream=$null
    $deadline=[Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(15));$failed=$false
    try{
        # Fixed authenticated repository API; no caller-controlled URL or token forwarding.
        $api.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:MEDIA_ACTIONS_TOKEN)
        $api.DefaultRequestHeaders.UserAgent.ParseAdd('OpenWebPBX-ClientCoreMedia/1.0')
        $response=$api.GetAsync('https://api.github.com/repos/embire2/openwebpbx/actions/artifacts/12444963981/zip',[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 302 -or !$response.Headers.Location -or !$response.Headers.Location.IsAbsoluteUri){throw 'The fixed engine artifact redirect is unavailable.'}
        $location=$response.Headers.Location
        if($location.Scheme -cne 'https' -or !$location.IsDefaultPort -or $location.UserInfo -or $location.Fragment -or $location.AbsoluteUri.Length -gt 16384){throw 'The authenticated engine storage URL refused.'}
        $response.Dispose();$response=$null
        # A separate client sends NO repository token, cookies or default credentials.
        $storageHandler=[Net.Http.HttpClientHandler]::new();$storageHandler.AllowAutoRedirect=$false;$storageHandler.UseCookies=$false;$storageHandler.UseDefaultCredentials=$false
        $storage=[Net.Http.HttpClient]::new($storageHandler);$storage.Timeout=[Threading.Timeout]::InfiniteTimeSpan
        $response=$storage.GetAsync($location,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$deadline.Token).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200 -or ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne 39161015)){throw 'The exact engine body length is unavailable.'}
        $stream=$response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
        CopyCoreEngineBody $stream $Target 39161015 '3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542' $deadline.Token
    }catch{$failed=$true}
    finally{if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($storage){$storage.Dispose()};if($storageHandler){$storageHandler.Dispose()};$api.Dispose();$handler.Dispose();$deadline.Dispose()}
    # Do not print signed storage URLs, response headers or repository credentials.
    if($failed){throw 'The pinned engine input could not be collected.'}
}

$msi=Join-Path $work 'client-core-media.msi';$engine=Join-Path $work 'client-core-engine.original.zip'
MediaGet 'https://github.com/signalwire/freeswitch/releases/download/v1.11.3/FreeSWITCH-1.11.3-Release-x64.msi' $msi 168300544
if((Get-Item -LiteralPath $msi).Length -ne 168300544 -or (Hash $msi) -cne 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d'){throw 'The exact original read-only MSI input differs.'}
GetCoreEngine $engine
$componentBinding=[ordered]@{schema=1;source_commit=$SourceCommit;producer_source_manifest_sha256=(Hash (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests/wav-producer/source-manifest.json'));sdk_sha256=(Hash $SdkZip);fresh_producer_sha256=$WavProducerSha256;engine_run_id='39823852979';engine_artifact_id='12444963981';engine_sha256=(Hash $engine);msi_sha256=(Hash $msi);native_Core_or_calling_qualified=$false;whole_workflow_accepted=$false}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($componentBinding|ConvertTo-Json -Compress));$out=[IO.File]::Open((Join-Path $evidence 'inputs.safe.json'),'CreateNew','Write','None');try{$out.Write($bytes,0,$bytes.Length);$out.Flush($true)}finally{$out.Dispose()}
& (Join-Path $PSScriptRoot 'Test-ClientMedia.ps1') -SdkZip $SdkZip -CoreMsi $msi -EngineZip $engine -SourceCommit $SourceCommit -Report (Join-Path $evidence 'report.json') -WavProducer $WavProducer -WavProducerSha256 $WavProducerSha256
# The caller still performs every original SDK/toolchain/system/cleanup guard.
# This script returning does not accept a workflow or override earlier failures.
