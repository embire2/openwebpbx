#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][ValidateSet('install','upgrade')][string]$Owner,[Parameter(Mandatory)][IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';. (Join-Path $PSScriptRoot 'WindowsPhoneCatalogue.Common.ps1')
Install-OpenWebWindowsPhoneCatalogue -PackageRoot $PackageRoot -Owner $Owner -MaintenanceLock $MaintenanceLock
