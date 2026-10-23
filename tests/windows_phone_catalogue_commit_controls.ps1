# Actual PHP nested process, exact descriptor adapter and binary/ephemeral-crypto tests.
param([Parameter(Mandatory)][string]$Php,[string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_proof.ps1')
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_sealed_output.ps1')
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_commit_output.ps1')
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue commit-output control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Body){$denied=$false;try{&$Body|Out-Null}catch{$denied=$true};Check $denied}
# Explicit ACL/native reader adapters. Actual bytes, CreateNew, PHP proc_open and crypto remain real.
function Assert-OpenWebRecoveryProtected {param([string]$Path,[switch]$Directory,[switch]$Private)if(!(Test-Path -LiteralPath $Path) -or ([IO.File]::GetAttributes($Path)-band [IO.FileAttributes]::ReparsePoint)){throw 'Fixture ordinary path refusal.'}}
function Set-OpenWebRecoveryPrivate {param([string]$Path)if(![IO.File]::Exists($Path)){throw 'Fixture private file absent.'}}
function Read-OpenWebRecoveryBytes {param([string]$Path,[int]$Maximum)$bytes=[IO.File]::ReadAllBytes($Path);if($bytes.Length-gt $Maximum){throw 'Fixture bounded read refused.'};return ,$bytes}
function PrivateFile([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
$Php=[IO.Path]::GetFullPath($Php);Check ([IO.File]::Exists($Php) -and !([IO.File]::GetAttributes($Php)-band [IO.FileAttributes]::ReparsePoint))
$library=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/updates/windows-phone-catalogue.php'));$adapted=Convert-WindowsPhoneCatalogueCommitCapture $library
$expected=$library.Replace("1=>['file','NUL','w']","1=>['file',(getenv('OPENWEB_CATALOGUE_COMMIT_STDOUT')?:'NUL'),'w']").Replace("2=>['file','NUL','w']","2=>['file',(getenv('OPENWEB_CATALOGUE_COMMIT_STDERR')?:'NUL'),'w']")
Check ($adapted-ceq $expected -and $adapted-cne $library)
foreach($n in 1,2){$literal=$n.ToString()+"=>['file','NUL','w']";Refuse {Convert-WindowsPhoneCatalogueCommitCapture ($library.Replace($literal,''))};Refuse {Convert-WindowsPhoneCatalogueCommitCapture ($library+$literal)}}
$at=$adapted.IndexOf("[0=>['pipe','r'],");$end=$adapted.IndexOf('],$pipes)',$at);Check ($at-ge 0 -and $end-gt $at);$descriptor=$adapted.Substring($at,$end+1-$at)
$anchor='if(proc_close($process)!==0)throw new RuntimeException(';Check (([regex]::Matches($library,[regex]::Escape($anchor))).Count-eq 1);$commitFailureLine=($library.Substring(0,$library.IndexOf($anchor)).Split([char]10)).Count;Check ($commitFailureLine-eq 53)
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_phone_catalogue_native.ps1'),[ref]$t,[ref]$e);Check (!$e)
foreach($name in 'StartPhp','FinishPhp'){$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $name},$true));Check ($node.Count-eq 1);.([scriptblock]::Create($node[0].Extent.Text))}
$work=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebPBX-Catalogue-QA-'+[Guid]::NewGuid().ToString('N'));$reports=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebPBX-Catalogue-Qualification-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$null=[IO.Directory]::CreateDirectory($reports);$ReportPath=Join-Path $reports 'native-Core.original.json'
$children=[Collections.Generic.List[object]]::new();$paths=[pscustomobject]@{Php=$Php;Ini=(Join-Path $work 'fixture.ini');Worker=(Join-Path $work 'worker.php')};$rsa=[Security.Cryptography.RSA]::Create(3072)
$beforeOut=[Environment]::GetEnvironmentVariable('OPENWEB_CATALOGUE_COMMIT_STDOUT');$beforeErr=[Environment]::GetEnvironmentVariable('OPENWEB_CATALOGUE_COMMIT_STDERR')
try{
 PrivateFile $paths.Ini '';PrivateFile (Join-Path $work 'descriptor.txt') $descriptor
 PrivateFile $paths.Worker @'
<?php
$descriptor=eval('return '.file_get_contents(__DIR__.'/descriptor.txt').';');
if(($argv[1]??'')==='--fallback'){echo json_encode([$descriptor[1][1],$descriptor[2][1]]);exit(0);}
$p=proc_open([PHP_BINARY,'-n','-r',"fwrite(STDOUT,hex2bin('00fffe804142'));fwrite(STDERR,hex2bin('ff000ac328'));exit(17);"],$descriptor,$pipes);
if(!is_resource($p))exit(7);fclose($pipes[0]);$exit=proc_close($p);
if($exit!==17)exit(8);
fwrite(STDERR,'{"schema":1,"producer":"windows_phone_catalogue_native.php","state":"failed","source_basename":"refresh.fixture.php","source_line":53,"error_type":"RuntimeException"}');exit(3);
'@
 $fallback=[Diagnostics.ProcessStartInfo]::new();$fallback.FileName=$Php;$fallback.Arguments='-n "'+$paths.Worker+'" --fallback';$fallback.UseShellExecute=$false;$fallback.RedirectStandardOutput=$true;$fallback.RedirectStandardError=$true;$fallback.EnvironmentVariables.Remove('OPENWEB_CATALOGUE_COMMIT_STDOUT');$fallback.EnvironmentVariables.Remove('OPENWEB_CATALOGUE_COMMIT_STDERR');$process=[Diagnostics.Process]::Start($fallback);try{$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();if(!$process.WaitForExit(10000)){throw 'The owned fallback control timed out.'};Check ($out.Wait(2000) -and $err.Wait(2000) -and $process.ExitCode-eq 0 -and $err.Result.Length-eq 0 -and $out.Result-ceq '["NUL","NUL"]')}finally{if(!$process.HasExited){$process.Kill();if(!$process.WaitForExit(10000)){throw 'The owned fallback control did not end.'}};$process.Dispose()}
 $child=StartPhp '--hold';$caught=$null;try{$null=FinishPhp $child}catch{$caught=$_}
 Check ($null-ne $caught -and $caught.Exception -is [InvalidOperationException] -and $caught.Exception.Data['catalogue_php_child_exit']-eq 3)
 Check ([Environment]::GetEnvironmentVariable('OPENWEB_CATALOGUE_COMMIT_STDOUT')-ceq $beforeOut -and [Environment]::GetEnvironmentVariable('OPENWEB_CATALOGUE_COMMIT_STDERR')-ceq $beforeErr)
 $binding=Read-WindowsPhoneCatalogueCommitBinding $caught.Exception.Data['catalogue_commit_original'];Check ($binding.stdout_bytes-eq 6 -and $binding.stderr_bytes-eq 5 -and $binding.bytes-eq 19 -and $binding.php_action-ceq '--hold' -and $binding.php_child_exit-eq 3)
 $raw=[IO.File]::ReadAllBytes((Get-WindowsPhoneCatalogueOriginalPath $ReportPath)+'.commit');Check ([Convert]::ToHexString($raw)-ceq '0600000000FFFE80414205000000FF000AC328')
 Refuse {New-WindowsPhoneCatalogueCommitCapture $work 0};Check ([IO.File]::ReadAllBytes((Get-WindowsPhoneCatalogueCommitPaths $work 0).stdout).Length-eq 6)
 Refuse {Get-WindowsPhoneCatalogueCommitPaths ([IO.Path]::GetTempPath()) 0};Refuse {Get-WindowsPhoneCatalogueCommitPaths $work -1};Refuse {Get-WindowsPhoneCatalogueCommitPaths $work 1001}
 foreach($field in @($binding.Keys)){$bad=[ordered]@{};foreach($n in $binding.Keys){if($n-cne $field){$bad[$n]=$binding[$n]}};Refuse {Read-WindowsPhoneCatalogueCommitBinding $bad}}
 foreach($change in @(@('schema',2),@('bytes',18),@('stdout_bytes',-1),@('stderr_bytes',65537),@('php_child_exit','3'),@('php_child_exit',2147483648),@('php_action','PRIVATE'),@('sha256','PRIVATE'))){$bad=[ordered]@{};foreach($n in $binding.Keys){$bad[$n]=$binding[$n]};$bad[$change[0]]=$change[1];Refuse {Read-WindowsPhoneCatalogueCommitBinding $bad}}
 $source='a'*40;$run='40009929505';$public=$rsa.ExportSubjectPublicKeyInfoPem();$sealed=Seal-WindowsPhoneCatalogueOriginal $raw $source $run 'Core' $public $binding
 $aad=[Convert]::FromBase64String($sealed.aad);$metadata=[Text.Encoding]::UTF8.GetString($aad)|ConvertFrom-Json;Check (@($metadata.PSObject.Properties).Count-eq 11 -and $metadata.stage-ceq 'commit_child' -and $metadata.encoding-ceq 'uint32le-length-prefixed-raw-v1' -and $metadata.php_child_exit-eq 3 -and $metadata.php_action-ceq '--hold' -and $metadata.plaintext_sha256-ceq $binding.sha256)
 $key=$rsa.Decrypt([Convert]::FromBase64String($sealed.wrapped_key),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256);$aes=[Security.Cryptography.AesGcm]::new($key,16)
 try{$nonce=[Convert]::FromBase64String($sealed.nonce);$cipher=[Convert]::FromBase64String($sealed.ciphertext);$tag=[Convert]::FromBase64String($sealed.tag);$plain=[byte[]]::new($cipher.Length);$aes.Decrypt($nonce,$cipher,$tag,$plain,$aad);Check ([Convert]::ToHexString($plain)-ceq [Convert]::ToHexString($raw));$aad[0]=$aad[0]-bxor 1;Refuse {$aes.Decrypt($nonce,$cipher,$tag,$plain,$aad)}}finally{$aes.Dispose();[Array]::Clear($key,0,$key.Length)}
 $publicPath=Join-Path $SourceRoot 'tests/windows_phone_catalogue_diagnostic_public.pem';$protected=Protect-WindowsPhoneCatalogueCommitOriginal $ReportPath $binding $publicPath $source $run Core 3;Check ($protected.public_key_sha256-ceq '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307')
 Refuse {Protect-WindowsPhoneCatalogueCommitOriginal $ReportPath $binding $publicPath $source $run Core 4}
 $bad=$raw.Clone();$bad[0]=$bad[0]-bxor 1;[IO.File]::WriteAllBytes((Get-WindowsPhoneCatalogueOriginalPath $ReportPath)+'.commit',$bad);Refuse {Protect-WindowsPhoneCatalogueCommitOriginal $ReportPath $binding $publicPath $source $run Core 3};[IO.File]::WriteAllBytes((Get-WindowsPhoneCatalogueOriginalPath $ReportPath)+'.commit',$raw)
 # Second real PHP child cannot replace the first original frame: original exit/type survives capture refusal.
 $second=StartPhp '--refresh';$again=$null;try{$null=FinishPhp $second}catch{$again=$_};Check ($again.Exception -is [InvalidOperationException] -and $again.Exception.Data['catalogue_php_child_exit']-eq 3 -and $again.Exception.Data['catalogue_commit_observation_refused']-ceq $true);Check ([Convert]::ToHexString([IO.File]::ReadAllBytes((Get-WindowsPhoneCatalogueOriginalPath $ReportPath)+'.commit'))-ceq [Convert]::ToHexString($raw))
 # A different PHP failure must not attach an earlier commit's files.
 $commitFailureLine++;$third=StartPhp '--read';$other=$null;try{$null=FinishPhp $third}catch{$other=$_};Check ($other.Exception -is [InvalidOperationException] -and !$other.Exception.Data.Contains('catalogue_commit_original') -and !$other.Exception.Data.Contains('catalogue_commit_observation_refused'));$commitFailureLine--
 $maximum=New-WindowsPhoneCatalogueCommitCapture $work 3;[IO.File]::WriteAllBytes($maximum.stdout,[byte[]]::new(65536));[IO.File]::WriteAllBytes($maximum.stderr,[byte[]]::new(65536));$maxReport=Join-Path $reports 'native-Desktop.original.json';$max=Write-WindowsPhoneCatalogueCommitOriginal $maxReport $work 3 '--refresh' 3;Check ($max.bytes-eq 131080)
 $maxEnvelope=Protect-WindowsPhoneCatalogueCommitOriginal $maxReport $max $publicPath $source $run Desktop 3;Check (($maxEnvelope|ConvertTo-Json -Compress).Length-lt 262144)
 [IO.File]::WriteAllBytes($maximum.stderr,[byte[]]::new(65537));Refuse {Write-WindowsPhoneCatalogueCommitOriginal $maxReport $work 3 '--refresh' 3}
 $empty=New-WindowsPhoneCatalogueCommitCapture $work 4;$emptyReports=Join-Path $work ('OpenWebPBX-Catalogue-Qualification-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($emptyReports);$emptyBinding=Write-WindowsPhoneCatalogueCommitOriginal (Join-Path $emptyReports 'native-Core.original.json') $work 4 '--hold' 3;Check ($emptyBinding.bytes-eq 8 -and $emptyBinding.stdout_bytes-eq 0 -and $emptyBinding.stderr_bytes-eq 0)
}finally{foreach($row in $children){if(!$row.Process.HasExited){$row.Process.Kill();if(!$row.Process.WaitForExit(10000)){throw 'The owned commit control child did not end.'}};$row.Process.Dispose()};$rsa.Dispose();[IO.Directory]::Delete($work,$true);[IO.Directory]::Delete($reports,$true)}
Write-Output ('PASS '+$checks+' actual PHP proc_open/raw bytes/descriptor/environment/CreateNew/crypto controls; ACL/native readers explicit adapters; no Windows commit pass')
