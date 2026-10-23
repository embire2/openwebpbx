# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$Output,[Parameter(Mandatory)][string]$Identity,[Parameter(Mandatory)][string]$Publisher,[Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,[string]$DevelopmentNonce)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Package on the disposable hosted Windows runner.'}
if($Identity -cnotmatch '^[A-Za-z0-9.-]{3,50}$' -or $Publisher -cnotmatch '^CN=[^\r\n<>]{3,160}$'){throw 'Package identity or publisher is invalid.'}
$AppRoot=[IO.Path]::GetFullPath($AppRoot);$Output=[IO.Path]::GetFullPath($Output)
if(!(Test-Path -LiteralPath (Join-Path $AppRoot 'OpenWebPbx.Phone.App.exe') -PathType Leaf) -or (Test-Path -LiteralPath $Output)){throw 'A fresh package output and published client are required.'}
$runner=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($path in @($AppRoot,$Output)){if(!$path.StartsWith($runner,[StringComparison]::OrdinalIgnoreCase)){throw 'Package paths must remain under the owned runner workspace.'};$parent=[IO.DirectoryInfo]::new((Split-Path $path -Parent));while($null-ne $parent){if($parent.Exists -and ($parent.Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Package ancestry is linked.'};$parent=$parent.Parent}}
if($DevelopmentNonce){if($DevelopmentNonce -cnotmatch '^[a-f0-9]{32}$' -or $Identity -cne ('OpenWebPBX.FreePhone.Dev.'+$DevelopmentNonce.Substring(0,16)) -or $Publisher -cne ('CN=FreePhone Development '+$DevelopmentNonce)){throw 'The development package identity must be nonce-bound.'}}
$tools=@(Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory|Where-Object{$_.Name-match '^10\.[0-9.]+$'}|Sort-Object {[version]$_.Name} -Descending)
$tool=$tools|ForEach-Object{Join-Path $_.FullName 'x64\makeappx.exe'}|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if(!$tool){throw 'The native Windows packaging tool is missing.'}
$payload=@(Get-ChildItem -LiteralPath $AppRoot -Recurse -Force)
if($payload.Count -gt 10000 -or (@($payload|Where-Object {!$_.PSIsContainer})|Measure-Object Length -Sum).Sum -gt 2GB){throw 'The published payload is unbounded.'}
foreach($item in $payload){
 if(($item.Attributes-band [IO.FileAttributes]::ReparsePoint) -or (!$item.PSIsContainer -and ($item.Extension -iin @('.pfx','.p12','.key','.snk') -or $item.Name -like '*.pubxml.user'))){throw 'A linked or private signing file cannot enter the package.'}
 if(!$item.PSIsContainer -and $item.Extension -iin @('.pem','.crt','.cer','.txt','.json','.xml','.config') -and $item.Length -le 1MB -and [IO.File]::ReadAllText($item.FullName) -match '-----BEGIN (?:RSA |EC |ENCRYPTED |OPENSSH )?PRIVATE KEY-----'){throw 'Private key material cannot enter the package.'}
}
$manifestPath=Join-Path $AppRoot 'AppxManifest.xml';if(Test-Path -LiteralPath $manifestPath){throw 'The published app already contains a manifest. Preserve and inspect it before packaging.'}
[xml]$manifest=Get-Content (Join-Path $PSScriptRoot '..\src\OpenWebPbx.Phone.App\Package.appxmanifest') -Raw
$manifest.Package.Identity.SetAttribute('Name',$Identity);$manifest.Package.Identity.SetAttribute('Publisher',$Publisher);$manifest.Package.Identity.SetAttribute('Version',($Version+'.0'));$manifest.Package.Identity.SetAttribute('ProcessorArchitecture','x64')
$manifest.Package.Resources.Resource.SetAttribute('Language','en-US')
$application=$manifest.Package.Applications.Application;$application.SetAttribute('Executable','OpenWebPbx.Phone.App.exe');$application.SetAttribute('EntryPoint','Windows.FullTrustApplication')
if($DevelopmentNonce){
 $ns=[Xml.XmlNamespaceManager]::new($manifest.NameTable);$ns.AddNamespace('uap','http://schemas.microsoft.com/appx/manifest/uap/windows10');$ns.AddNamespace('desktop','http://schemas.microsoft.com/appx/manifest/desktop/windows10')
 $manifest.SelectSingleNode('//uap:Protocol',$ns).SetAttribute('Name',('openwebpbx-dev-'+$DevelopmentNonce.Substring(0,16)))
 $association=$manifest.SelectSingleNode('//uap:FileTypeAssociation',$ns);$association.SetAttribute('Name',('freephone-development-'+$DevelopmentNonce.Substring(0,16)));$association.SelectSingleNode('uap:SupportedFileTypes/uap:FileType',$ns).InnerText='.freephone-dev-'+$DevelopmentNonce.Substring(0,16)
 $task=$manifest.SelectSingleNode('//desktop:StartupTask',$ns);$task.SetAttribute('TaskId',('FreePhoneDevelopment'+$DevelopmentNonce));$task.ParentNode.SetAttribute('Executable','OpenWebPbx.Phone.App.exe')
}
$manifest.Save($manifestPath)
$parent=Split-Path $Output -Parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null
& $tool pack /d $AppRoot /p $Output /o;if($LASTEXITCODE){throw 'Native package validation failed.'}
