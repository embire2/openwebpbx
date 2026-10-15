# Test-only failure observation. The product helper and its guards are unchanged.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CertificateThumbprint,[Parameter(Mandatory)][string]$ReportPath)

function Get-BackupTlsFailure($Failure){
 $types=@('RuntimeException','MethodInvocationException','InvalidOperationException','UnauthorizedAccessException','IOException','FileNotFoundException','ItemNotFoundException','CryptographicException','Win32Exception','COMException','ParameterBindingException','CommandNotFoundException','PSArgumentException','ActionPreferenceStopException')
 $sources=@('Enable-PhoneTLS.ps1','Restore-Gates.ps1','Write-PrivateState.ps1','windows-backup-tls-observer.ps1')
 $type=$Failure.Exception.GetType().Name
 $safe=@{schema=1;operation='prepare_restored_tls';state='failed';error_type=if($type -cin $types){$type}else{'unknown'};failure_class='unknown';source_frames=@()}
 $classes=@{
  'Install the PBX before enabling secure phone connections.'='configuration_missing'
  'Complete interrupted backup recovery before configuring phone certificates.'='restore_blocked'
  'Offline certificate preparation requires restored calls to remain held and stopped.'='calls_not_held_and_stopped'
  'Set a public PBX hostname and trusted HTTPS certificate before enabling Android phones.'='public_hostname'
  'Choose a current, exportable certificate issued by a trusted certificate authority.'='certificate_not_eligible'
  'Windows could not verify the phone certificate chain.'='certificate_chain'
  'The certificate chain file is too large.'='certificate_chain_size'
  'Private certificate backup access could not be secured.'='backup_access'
  'Private phone certificate access could not be secured.'='certificate_access'
  'Secure phone setup failed.'='native_php'
 }
 foreach($message in $classes.Keys){if($message -ceq [string]$Failure.Exception.Message){$safe.failure_class=$classes[$message];break}}
 $first=[IO.Path]::GetFileName(([string]$Failure.InvocationInfo.ScriptName).Replace('\','/'));$line=$Failure.InvocationInfo.ScriptLineNumber
 if($first -cin $sources -and $line -ge 1 -and $line -le 20000){$safe.source_frames+=@{source_basename=$first;source_line=[int]$line}}
 foreach($match in [regex]::Matches([string]$Failure.ScriptStackTrace,'(?m), ([^\r\n]+): line ([0-9]{1,5})\s*$')){
  $name=[IO.Path]::GetFileName($match.Groups[1].Value.Replace('\','/'));$line=[int]$match.Groups[2].Value
  if($name -cin $sources -and $line -ge 1 -and $line -le 20000){
   if(!@($safe.source_frames|Where-Object {$_.source_basename -ceq $name -and $_.source_line -eq $line}).Count){$safe.source_frames+=@{source_basename=$name;source_line=$line}}
   if($safe.source_frames.Count -eq 8){break}
  }
 }
 $cause=$Failure.Exception
 for($depth=0;$cause -and $depth -lt 4;$depth++){
  if($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -ge 0 -and $cause.NativeErrorCode -le 65535){$safe.native_code=[int]$cause.NativeErrorCode;break}
  $cause=$cause.InnerException
 }
 $safe.hresult=[int]$Failure.Exception.HResult
 $php=$Failure.Exception.Data['OpenWebPhoneTLSPhpFailure']
 if($php -and ($php.schema -is [int] -or $php.schema -is [long]) -and $php.schema -eq 1 -and $php.error_type -is [string] -and $php.error_type -cin @('RuntimeException','InvalidArgumentException','PDOException','TypeError','Error','ValueError','Exception') -and $php.source_basename -is [string] -and $php.source_basename -cin @('phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php','external_component') -and ($php.source_line -is [int] -or $php.source_line -is [long]) -and $php.source_line -ge 1 -and $php.source_line -le 100000 -and $php.stage -is [string] -and $php.stage -cin @('idle','bind','resume','ready','apply','rollback','initialization')){
  $safe.php_failure=@{error_type=$php.error_type;source_basename=$php.source_basename;source_line=[int]$php.source_line;stage=$php.stage}
 }
 return $safe
}

function Invoke-ObservedBackupTlsPreparation([string]$Thumbprint,[string]$OutputPath){
 try{& 'C:/OpenWebPBX/tools/Enable-PhoneTLS.ps1' -CertificateThumbprint $Thumbprint -PrepareRestored}
 catch{
  $original=$_
  try{
   $safe=Get-BackupTlsFailure $original;$json=ConvertTo-Json -InputObject $safe -Depth 8 -Compress
   if($json.Length -le 8192){[IO.File]::WriteAllText($OutputPath,$json,[Text.UTF8Encoding]::new($false))}
  }catch{}
  throw $original
 }
}

if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or $env:OPENWEB_WINDOWS_BACKUP_TEST -cne '1'){throw 'Only the disposable hosted backup qualification may observe preparation.'}
$expected=Join-Path $env:ProgramData 'OpenWebPBX/backup-qualification/tls-prepare-failure.json'
if($CertificateThumbprint -cnotmatch '^[a-fA-F0-9]{40,64}$' -or [IO.Path]::GetFullPath($ReportPath) -cne [IO.Path]::GetFullPath($expected) -or (Test-Path -LiteralPath $ReportPath)){throw 'The exact fresh private preparation observation is required.'}
for($part=Split-Path -Parent $ReportPath;$part;$part=Split-Path -Parent $part){if(!(Test-Path -LiteralPath $part -PathType Container) -or ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Private ordinary preparation evidence directory required.'}}
Invoke-ObservedBackupTlsPreparation $CertificateThumbprint $ReportPath
