[CmdletBinding()]
param([switch]$Check)
# One public entry point. The signed component is verified by Invoke before any
# updater executable is started; this launcher only stages the known bundle.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Please open Start-UpgradePathRepair.cmd using Windows PowerShell.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$administrator = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$administrator) {
    try {
        $command = "& '" + $PSCommandPath.Replace("'", "''") + "'"
        if ($Check) { $command += ' -Check' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = Start-Process -FilePath $powershell -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        exit $child.ExitCode
    } catch {
        Write-Host 'Administrator permission is needed to update the server. No update was started.' -ForegroundColor Red
        exit 1
    }
}

$adminOwners = @('S-1-5-18', 'S-1-5-32-544', $identity.User.Value)
$adminOwners += @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.SID.Value })
$adminOwners = @($adminOwners | Where-Object { $_ -cnotin @('S-1-1-0', 'S-1-5-11', 'S-1-5-7', 'S-1-5-32-545', 'S-1-5-32-546') } | Select-Object -Unique)
$writers = @('S-1-5-18', 'S-1-5-32-544')
$private = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'OpenWebPBX'
$work = Join-Path $private 'upgrade-path-repair'
$launcher = $null
$transition = $null

if (!('OpenWebPBXRepairLauncher.NativeFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace OpenWebPBXRepairLauncher {
 public static class NativeFile {
  [StructLayout(LayoutKind.Sequential)] struct Information {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
   public System.Runtime.InteropServices.ComTypes.FILETIME Access; public System.Runtime.InteropServices.ComTypes.FILETIME Write;
   public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out Information info);
  public static bool MultipleLinks(string path) {
   using(var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
    Information info; if(!GetFileInformationByHandle(file.SafeFileHandle, out info)) throw new Win32Exception();
    return info.Links != 1;
   }
  }
 }
}
'@
}

function Assert-Unlinked([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'Use files extracted to a local Windows drive.' }
    $current = $full
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked repair paths are not allowed.' }
        $parent = Split-Path $current -Parent
        if (!$parent -or $parent -ieq $current) { break }
        $current = $parent
    }
    Get-Item -LiteralPath $full -Force
}
function Assert-SourceFile([string]$Path, [long]$Maximum) {
    $item = Assert-Unlinked $Path
    if ($item.PSIsContainer -or $item.Length -gt $Maximum -or [OpenWebPBXRepairLauncher.NativeFile]::MultipleLinks($item.FullName)) {
        throw 'The extracted repair bundle contains an unsupported or linked file.'
    }
    $item
}
function Assert-Protected([string]$Path, [bool]$Directory) {
    $item = Assert-Unlinked $Path
    if ([bool]$item.PSIsContainer -ne $Directory) { throw 'A protected repair path has the wrong type.' }
    if (!$Directory -and [OpenWebPBXRepairLauncher.NativeFile]::MultipleLinks($item.FullName)) { throw 'A protected repair input is a hard link.' }
    $acl = Get-Acl -LiteralPath $item.FullName
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin $adminOwners) { throw 'An existing repair path has an untrusted owner.' }
    foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($ace.AccessControlType -eq 'Allow' -and ([int]$ace.FileSystemRights -band 852310) -and $ace.IdentityReference.Value -cnotin $adminOwners) {
            throw 'An existing repair path permits changes outside verified local Administrators and SYSTEM.'
        }
    }
}
function New-ProtectedDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Assert-Protected $Path $true; return }
    Assert-Protected (Split-Path $Path -Parent) $true
    $null = [IO.Directory]::CreateDirectory($Path)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($value in $writers) {
        $sid = New-Object Security.Principal.SecurityIdentifier($value)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-Protected $Path $true
}
function Open-ProtectedLock([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) {
        $new = [IO.File]::Open($Path, 'CreateNew', 'ReadWrite', 'Read')
        $new.Dispose()
    }
    Assert-Protected $Path $false
    [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
}
function Assert-RelativeName([string]$Name) {
    foreach ($part in $Name.Split('\')) {
        if (!$part -or $part -in '.', '..' -or $part -match '[\x00-\x1f\x7f/:<>"|?*]' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$') {
            throw 'The extracted repair bundle contains an unsafe Windows filename.'
        }
    }
}

try {
    Write-Host 'Preparing the OpenWebPBX server update. Existing calls stay running during preparation.'
    Assert-Protected $private $true
    Assert-Protected (Join-Path $private 'installation.json') $false
    New-ProtectedDirectory $work
    $launcher = Open-ProtectedLock (Join-Path $work 'launcher.lock')
    # Do not replace inputs while another copy of Invoke owns a transaction.
    $transition = Open-ProtectedLock (Join-Path $work 'transition.lock')
    $source = (Assert-Unlinked $PSScriptRoot).FullName.TrimEnd('\')
    if ($source -ieq $work -or $source.StartsWith($work + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Extract the public repair download into a separate folder before starting it.'
    }
    $inputs = @{}
    foreach ($name in @('Invoke-UpgradePath.ps1', 'UpgradePath.Download.ps1', 'repair-updater-manifest.json')) {
        $inputs[$name] = (Assert-SourceFile (Join-Path $source $name) 1048576).FullName
    }
    foreach ($name in @('1.0.21.json', '1.0.22.json', '1.0.23.json', 'windows-upgrade-path.json')) {
        $relative = 'catalogue\' + $name
        $inputs[$relative] = (Assert-SourceFile (Join-Path $source $relative) 262144).FullName
    }
    $runner = (Assert-Unlinked (Join-Path $source 'runner')).FullName.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $runner -Recurse -Force | ForEach-Object {
        $item = Assert-Unlinked $_.FullName
        if (!$item.PSIsContainer) { Assert-SourceFile $item.FullName 134217728 }
    })
    if ($files.Count -ne 227 -or !(Test-Path -LiteralPath (Join-Path $runner 'OpenWebPbx.Updater.exe') -PathType Leaf)) {
        throw 'Please extract the complete repair download; its 227 updater files are required.'
    }
    foreach ($file in $files) {
        $relative = 'runner\' + $file.FullName.Substring($runner.Length + 1)
        Assert-RelativeName $relative
        if ($inputs.ContainsKey($relative)) { throw 'The bundle contains duplicate Windows paths.' }
        $inputs[$relative] = $file.FullName
    }
    $bundles = Join-Path $work 'bundles'
    New-ProtectedDirectory $bundles
    $stage = Join-Path $bundles ([Guid]::NewGuid().ToString('N'))
    New-ProtectedDirectory $stage
    foreach ($relative in ($inputs.Keys | Sort-Object)) {
        $destination = Join-Path $stage $relative
        $parents = @(); $parent = Split-Path $destination -Parent
        while ($parent -ine $stage) { $parents += $parent; $parent = Split-Path $parent -Parent }
        for ($index = $parents.Count - 1; $index -ge 0; $index--) { New-ProtectedDirectory $parents[$index] }
        [IO.File]::Copy($inputs[$relative], $destination, $false)
        Assert-Protected $destination $false
        if ((Get-FileHash -LiteralPath $inputs[$relative] -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { throw 'A repair input changed during preparation; please use a fresh download.' }
    }
    $archives = Join-Path $work 'archives'
    New-ProtectedDirectory $archives
    $arguments = @{
        RepairRoot = (Join-Path $stage 'runner')
        RepairManifest = (Join-Path $stage 'repair-updater-manifest.json')
        LatestFeed = (Join-Path $stage 'catalogue\1.0.23.json')
        UpgradeCatalogue = (Join-Path $stage 'catalogue\windows-upgrade-path.json')
        HistoricalFeeds = (Join-Path $stage 'catalogue')
        ArchiveDirectory = $archives
    }
    $transition.Dispose(); $transition = $null
    # Invoke verifies RSA and every signed component file before calling runner.
    if ($Check) { $arguments.Check = $true }
    & (Join-Path $stage 'Invoke-UpgradePath.ps1') @arguments
    if ($Check) { Write-Host 'OpenWebPBX update verification completed. No server version was installed.' -ForegroundColor Green }
    else { Write-Host 'OpenWebPBX server update completed. You may close this window.' -ForegroundColor Green }
    exit 0
} catch {
    Write-Host ('The update could not finish: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Your previous files and recovery records have been kept. Keep this message for your administrator.'
    exit 1
} finally {
    if ($transition) { $transition.Dispose() }
    if ($launcher) { $launcher.Dispose() }
}
