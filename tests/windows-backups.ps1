#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$AdminEmail,[Parameter(Mandatory)][SecureString]$AdminPassword,[switch]$DisposableFactory,[string]$SftpConfig)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableFactory -or $env:GITHUB_ACTIONS -ne 'true'){throw 'Run only on an explicitly disposable hosted Windows qualification factory.'}
$private=Join-Path $env:ProgramData 'OpenWebPBX\backup-qualification';New-Item -ItemType Directory -Force $private|Out-Null
& icacls.exe $private /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private qualification permissions could not be secured.'}
$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
try{$password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
$input=Join-Path $private ([Guid]::NewGuid().ToString('N')+'.json')
$value=@{admin_email=$AdminEmail;admin_password=$password;package_root=[IO.Path]::GetFullPath($PackageRoot);report=(Join-Path $private 'report.json');fixture_php=(Join-Path $PSScriptRoot 'windows-backups-fixture.php');sftp_config=$SftpConfig}
[IO.File]::WriteAllText($input,($value|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)));$password=$null;$value=$null
$prior=$env:OPENWEB_WINDOWS_BACKUP_TEST;$env:OPENWEB_WINDOWS_BACKUP_TEST='1'
try{
 & 'C:\OpenWebPBX\backup-runtime\python.exe' -I (Join-Path $PSScriptRoot 'pbx_windows_backup_unicode.py') PortableTransport 1>(Join-Path $private 'unicode-private.out') 2>(Join-Path $private 'unicode-private.err')
 if($LASTEXITCODE){throw 'Native backup SQL transport controls failed; private evidence retained.'}
 $priorProtocolPowerShell=$env:OPENWEB_TEST_PWSH
 try{
  $env:OPENWEB_TEST_PWSH=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
  & 'C:\OpenWebPBX\backup-runtime\python.exe' -I (Join-Path $PSScriptRoot 'windows_backup_control_protocol.py') 1>(Join-Path $private 'protocol-private.out') 2>(Join-Path $private 'protocol-private.err')
  if($LASTEXITCODE){throw 'Native backup control protocol tests failed; private evidence retained.'}
  & 'C:\OpenWebPBX\backup-runtime\python.exe' -I -B (Join-Path $PSScriptRoot 'windows_private_state.py') 1>(Join-Path $private 'private-state-private.out') 2>(Join-Path $private 'private-state-private.err')
  if($LASTEXITCODE){throw 'Native private-state writer tests failed; private evidence retained.'}
 }finally{
  if($null -eq $priorProtocolPowerShell){Remove-Item Env:\OPENWEB_TEST_PWSH -ErrorAction SilentlyContinue}else{$env:OPENWEB_TEST_PWSH=$priorProtocolPowerShell}
 }
 & 'C:\OpenWebPBX\backup-runtime\python.exe' -I (Join-Path $PSScriptRoot 'windows_backups_native.py') $input 1>(Join-Path $private 'child-private.out') 2>(Join-Path $private 'child-private.err')
 if($LASTEXITCODE){throw 'Native backup qualification failed; private report retained. No passing hosted result is implied.'}
}finally{
 Remove-Item -LiteralPath $input -Force -ErrorAction SilentlyContinue
 if($null -eq $prior){Remove-Item Env:\OPENWEB_WINDOWS_BACKUP_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_BACKUP_TEST=$prior}
}
