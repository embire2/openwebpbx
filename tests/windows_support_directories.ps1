# Exact support directory ownership. Pure controls never create/restore product data.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$SealedRecord,[string]$Output)
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw 'Support directory ownership control failed.'};$script:checks++}
function Refuse([scriptblock]$Action){try{& $Action}catch{$script:checks++;return};throw 'Malformed support directory inventory was accepted.'}
$source=Join-Path $SourceRoot 'packaging\windows\Support-Recovery.ps1';$sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Check ($errors.Count-eq 0)
foreach($name in 'Get-OpenWebSupportDirectoryMap','Resolve-OpenWebSupportDirectory'){
 $found=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true));Check ($found.Count-eq 1)
 . ([scriptblock]::Create($found[0].Extent.Text))
}
$root='C:\Owned-PBX-Fixture';$state='C:\Owned-PBX-State';$map=Get-OpenWebSupportDirectoryMap -Root $root -StateRoot $state
Check ($map.Count-eq 24)
$new=@{'tenant-backups'="$state\tenant-backups";'tenant-backup-downloads'="$state\tenant-backup-downloads";'protection'="$state\protection";'protection-status'="$state\protection-status";'protection-inbox'="$state\protection-inbox";'upload-admission'="$state\upload-admission";'upload-gate'="$root\upload-gate"}
foreach($name in $new.Keys){Check ($map[$name]-ceq$new[$name])}
foreach($name in $map.Keys){
 foreach($exists in $true,$false){$actual=Resolve-OpenWebSupportDirectory -Name $name -Entry ([pscustomobject]@{Path=$map[$name];Exists=$exists}) -Root $root -StateRoot $state;Check ($actual-ceq[IO.Path]::GetFullPath($map[$name]))}
 Refuse {Resolve-OpenWebSupportDirectory -Name $name -Entry ([pscustomobject]@{Path="$state\wrong-owned-directory";Exists=$false}) -Root $root -StateRoot $state}
}
# Unknown names cannot borrow an otherwise valid path; existing broad roots do
# not authorize a different folder for a known inventory name.
Refuse {Resolve-OpenWebSupportDirectory -Name 'unknown' -Entry ([pscustomobject]@{Path=$map['tenant-backups'];Exists=$true}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'TENANT-BACKUPS' -Entry ([pscustomobject]@{Path=$map['tenant-backups'];Exists=$true}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'tenant-backups' -Entry ([pscustomobject]@{Path=$map['protection'];Exists=$true}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'tenant-backups' -Entry ([pscustomobject]@{Path="$state\tenant-backups\..\protection";Exists=$true}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'tenant-backups' -Entry ([pscustomobject]@{Path='C:\Unrelated\tenant-backups';Exists=$true}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'tenant-backups' -Entry ([pscustomobject]@{Path=$map['tenant-backups'];Exists='false'}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'tenant-backups' -Entry ([pscustomobject]@{Path=42;Exists=$false}) -Root $root -StateRoot $state}
Refuse {Resolve-OpenWebSupportDirectory -Name 'tenant-backups' -Entry $null -Root $root -StateRoot $state}
$save=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Save-OpenWebSupport'},$true)
$restore=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Restore-OpenWebSupport'},$true)
Check ($save.Extent.Text.Contains('$directories=Get-OpenWebSupportDirectoryMap -Root $Root -StateRoot $StateRoot'))
Check ($restore.Extent.Text.Contains('$directoryTargets[$entry.Name]=Resolve-OpenWebSupportDirectory'))
Check ($restore.Extent.Text.IndexOf('Resolve-OpenWebSupportDirectory')-lt$restore.Extent.Text.IndexOf('Remove-OpenWebLegacyOnboardingTask'))
Check ($restore.Extent.Text.Contains('$target=Check-SupportPath $directoryTargets[$entry.Name]'))
$sealedCount=0;$sealedHash=$null
if($SealedRecord){
 $sealedHash=(Get-FileHash -LiteralPath $SealedRecord -Algorithm SHA256).Hash.ToLowerInvariant();$record=Get-Content -LiteralPath $SealedRecord -Raw|ConvertFrom-Json;Check ($record.schema-eq 1 -and $record.Directories-is[pscustomobject])
 foreach($entry in $record.Directories.PSObject.Properties){$null=Resolve-OpenWebSupportDirectory -Name $entry.Name -Entry $entry.Value -Root 'C:\OpenWebPBX' -StateRoot 'C:\ProgramData\OpenWebPBX';$sealedCount++;$checks++}
 Check ((Get-FileHash -LiteralPath $SealedRecord -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$sealedHash)
}
Check ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$sourceHash)
$result=[ordered]@{passed=$true;controls=$checks;source_sha256=$sourceHash;fixed_directory_count=$map.Count;new_directory_count=$new.Count;sealed_directory_count=$sealedCount;sealed_record_sha256=$sealedHash;source_and_sealed_record_unchanged=$true;product_or_recovery_writers_called=$false;actual_ps_version=$PSVersionTable.PSVersion.ToString()}
if($Output){[IO.File]::WriteAllText($Output,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
$result|ConvertTo-Json -Compress
