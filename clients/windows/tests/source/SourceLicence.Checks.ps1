# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual licence inventory/filesystem controls; invented text, no licence conclusion.
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $client 'tools/Collect-CorrespondingSource.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The collector does not parse.'}
foreach($name in 'SourceHash','AssertSourceRelative','GetSourceLicenceMaterials'){
 $matches=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($matches.Count -ne 1){throw 'The actual source helper is ambiguous.'};. ([scriptblock]::Create($matches[0].Extent.Text))
}
$checks=0
function CheckLicence([bool]$Value){if(!$Value){throw 'An actual licence inventory control failed.'};$script:checks++}
function DenyLicence([scriptblock]$Action){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};CheckLicence $refused}
$work=Join-Path ([IO.Path]::GetTempPath()) ('phone-source-licences-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path (Join-Path $work 'vendor/sample')
try{
 $body=[Text.Encoding]::ASCII.GetBytes('Invented inline notice for a filesystem control.')
 $path=Join-Path $work 'vendor/sample/source.c';[IO.File]::WriteAllBytes($path,$body)
 $hash=SourceHash $path
 $notice=[pscustomobject]@{component='vendor/sample';commit=('a'*40);path='vendor/sample/source.c';bytes=$body.Length;sha256=$hash;declaration='upstream_copyright_disclaimer'}
 $repo=[pscustomobject]@{path='vendor/sample';commit=('a'*40)}
 $file=[ordered]@{path=$notice.path;bytes=$body.Length;sha256=$hash;kind='regular';link_target='';git_mode=420}
 $named=[ordered]@{path='client/LICENSE';bytes=1L;sha256=('b'*64);kind='regular';link_target='';git_mode=420}
 $result=@(GetSourceLicenceMaterials @($file,$named) @($repo) @($notice) $work)
 CheckLicence ($result.Count -eq 2 -and $result[1].licence_basis -ceq 'pinned_inline_source_notice' -and $result[1].sha256 -ceq $hash -and $result[1].component_commit -ceq $repo.commit)
 DenyLicence {GetSourceLicenceMaterials @($file,$named) @($repo) @($notice,$notice) $work}
 DenyLicence {GetSourceLicenceMaterials @($file,$named) @() @($notice) $work}
 DenyLicence {GetSourceLicenceMaterials @($named) @($repo) @($notice) $work}
 foreach($variant in @('commit','path','component','sha256','bytes','declaration')){
  $bad=$notice|ConvertTo-Json|ConvertFrom-Json
  switch($variant){'commit'{$bad.commit='c'*40}'path'{$bad.path='vendor/other/source.c'}'component'{$bad.component='vendor/other'}'sha256'{$bad.sha256='0'*64}'bytes'{$bad.bytes=$true}'declaration'{$bad.declaration='unreviewed'}}
  DenyLicence {GetSourceLicenceMaterials @($file,$named) @($repo) @($bad) $work}
 }
 $badFile=[ordered]@{};foreach($key in $file.Keys){$badFile[$key]=$file[$key]};$badFile.kind='symlink_description'
 DenyLicence {GetSourceLicenceMaterials @($badFile,$named) @($repo) @($notice) $work}
 [IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3));DenyLicence {GetSourceLicenceMaterials @($file,$named) @($repo) @($notice) $work}
 $lock=Get-Content (Join-Path $client 'native/source-lock.json') -Raw|ConvertFrom-Json
 CheckLicence ($lock.policy.inline_licence_material.Count -eq 3 -and @($lock.policy.inline_licence_material|Where-Object component -CEQ 'vendor/linphone-sdk/external/bv16-floatingpoint').Count -eq 2 -and @($lock.policy.inline_licence_material|Where-Object component -CEQ 'vendor/linphone-sdk/external/sqlite3').Count -eq 1)
}finally{[IO.Directory]::Delete($work,$true)}
Write-Output ('PASS '+$checks+' actual licence inventory/filesystem controls; complete source collection and binary correspondence remain unqualified')
