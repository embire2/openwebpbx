# SPDX-License-Identifier: AGPL-3.0-or-later
# Failure-only existing local event reads. No audit/configuration/trace changes.
[CmdletBinding()]param([Parameter(Mandatory)][string]$Request,[Parameter(Mandatory)][string]$Report)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$WarningPreference='SilentlyContinue'
if($PSEdition -ceq 'Desktop'){$env:PSModulePath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"}

function RuleIdentityHash($Value){
 if($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9_.{}-]{1,160}\z'){return $null}
 $raw=[Text.Encoding]::ASCII.GetBytes($Value.ToLowerInvariant().Trim('{}'));$hash=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($hash.ComputeHash($raw))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function ReadEventFields([string]$Raw){
 if($Raw.Length -gt 65536 -or $Raw -match '<!\s*(?:DOCTYPE|ENTITY)'){throw 'Bounded local event XML required.'}
 $doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null;$doc.LoadXml($Raw);$out=@{}
 foreach($node in @($doc.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']"))){
  $name=$node.GetAttribute('Name');if($name.Length -gt 128 -or $out.ContainsKey($name)){throw 'Unique fixed event fields required.'};$out[$name]=[string]$node.InnerText
 }
 $out
}
function ImageCategory($Image){
 if($Image -isnot [string] -or !$Image -or $Image.Length -gt 1024){return [ordered]@{path_class='not_available';signer_class='not_sampled'}}
 if($Image -ceq 'System'){return [ordered]@{path_class='system_pseudo_image';signer_class='not_sampled'}}
 if($Image -cnotmatch '^[A-Za-z]:\\[^<>:"|?*\x00-\x1f]+$' -or $Image.Contains('..')){return [ordered]@{path_class='other_not_exported';signer_class='not_sampled'}}
 $full=[IO.Path]::GetFullPath($Image);if([IO.Path]::GetExtension($full) -ine '.exe'){return [ordered]@{path_class='other_not_exported';signer_class='not_sampled'}};$windows=$env:SystemRoot.TrimEnd('\')+'\';$defender=@(($env:ProgramFiles.TrimEnd('\')+'\Windows Defender\'),($env:ProgramData.TrimEnd('\')+'\Microsoft\Windows Defender\'))
 $trusted=$full.StartsWith($windows,[StringComparison]::OrdinalIgnoreCase);$kind=if($trusted){'windows_image'}else{'other_not_exported'}
 foreach($prefix in $defender){if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$trusted=$true;$kind='defender_image'}}
 if(!$trusted){if($full -match '(?i)\\phone-client-media-[a-f0-9]{32}\\'){$kind='owned_fixture_pattern_after_cleanup'};return [ordered]@{path_class=$kind;signer_class='not_sampled'}}
 if(![IO.File]::Exists($full)){return [ordered]@{path_class=$kind;signer_class='file_not_available'}}
 try{
  $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
  if($item -isnot [IO.FileInfo] -or $item.Length -le 0 -or $item.Length -gt 64MB -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Ordinary image required.'}
  $walk=$item.Directory;while($null -ne $walk){if($walk.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Ordinary image ancestors required.'};$walk=$walk.Parent}
  $signature=Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop
  $class=if($signature.Status.ToString() -cne 'Valid'){'not_valid'}elseif($null -ne $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match '(?:^|,\s*)CN=Microsoft (?:Windows(?: Publisher)?|Corporation)(?:,|$)'){'valid_Microsoft'}else{'valid_other'}
  [ordered]@{path_class=$kind;signer_class=$class}
 }catch{[ordered]@{path_class=$kind;signer_class='unavailable'}}
}
function QueryExistingEvents([string]$Kind,[datetime]$Start,[datetime]$End){
 $filter=switch($Kind){
  'scm'{@{LogName='System';ProviderName='Service Control Manager';Id=@(7036,7040,7045);StartTime=$Start;EndTime=$End}}
  'firewall'{@{LogName='Microsoft-Windows-Windows Firewall With Advanced Security/Firewall';ProviderName='Microsoft-Windows-Windows Firewall With Advanced Security';StartTime=$Start;EndTime=$End}}
  'defender'{@{LogName='Microsoft-Windows-Windows Defender/Operational';ProviderName='Microsoft-Windows-Windows Defender';StartTime=$Start;EndTime=$End}}
  default{throw 'Fixed existing local channel required.'}
 }
 try{$records=@(Get-WinEvent -FilterHashtable $filter -MaxEvents 65 -ErrorAction Stop);[pscustomobject]@{state=if($records.Count -gt 64){'capped'}else{'observed'};records=$records}}
 catch{[pscustomobject]@{state=if($_.FullyQualifiedErrorId.StartsWith('NoMatchingEventsFound',[StringComparison]::Ordinal)){'empty'}else{'unavailable'};records=@()}}
}
function WriteSafe([string]$Path,$Value){
 $raw=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 8 -Compress));if($raw.Length -gt 65536){throw 'Bounded closed event report required.'}
 $file=[IO.File]::Open($Path,'CreateNew','Write','None');try{$file.Write($raw,0,$raw.Length);$file.Flush($true)}finally{$file.Dispose()}
}

if($env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Owned disposable Windows scope required.'}
$work=Join-Path $env:RUNNER_TEMP 'phone-system-provenance-evidence/private-work'
if(![string]::Equals([IO.Path]::GetFullPath($Request),[IO.Path]::GetFullPath((Join-Path $work 'request.json')),[StringComparison]::OrdinalIgnoreCase) -or ![string]::Equals([IO.Path]::GetFullPath($Report),[IO.Path]::GetFullPath((Join-Path $work 'events.safe.json')),[StringComparison]::OrdinalIgnoreCase)){throw 'Exact owned event paths required.'}
if((Get-Item -LiteralPath $Request).Length -gt 16384 -or (Test-Path -LiteralPath $Report)){throw 'New bounded event request required.'}
$requestValue=Get-Content -LiteralPath $Request -Raw|ConvertFrom-Json
$names=@($requestValue.PSObject.Properties.Name|Sort-Object);if(($names -join '|') -cne 'end_utc|rule_identity_sha256|schema|service_names|start_utc' -or ($requestValue.schema -isnot [int] -and $requestValue.schema -isnot [long]) -or $requestValue.schema -ne 1 -or $requestValue.start_utc -isnot [string] -or $requestValue.end_utc -isnot [string] -or $requestValue.service_names -isnot [array] -or $requestValue.rule_identity_sha256 -isnot [array]){throw 'Closed event request required.'}
$start=[DateTimeOffset]::Parse($requestValue.start_utc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime;$end=[DateTimeOffset]::Parse($requestValue.end_utc,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
if($end -lt $start -or ($end-$start).TotalSeconds -gt 2704){throw 'Bounded original observation interval required.'}
$services=@($requestValue.service_names);$rules=@($requestValue.rule_identity_sha256)
if($services.Count -gt 16 -or $rules.Count -gt 16 -or @($services|Select-Object -Unique).Count -ne $services.Count -or @($rules|Select-Object -Unique).Count -ne $rules.Count){throw 'Bounded unique original delta identities required.'}
foreach($name in $services){if($name -isnot [string] -or $name -cnotmatch '^[A-Za-z0-9_.-]{1,128}\z'){throw 'Original service identity required.'}}
foreach($hash in $rules){if($hash -isnot [string] -or $hash -cnotmatch '^[a-f0-9]{64}\z'){throw 'Original firewall identity digest required.'}}
$clock=[Diagnostics.Stopwatch]::StartNew();$logs=[Collections.Generic.List[object]]::new();$transitions=[Collections.Generic.List[object]]::new();$firewall=[Collections.Generic.List[object]]::new();$parseRefused=0;$defenderCount=0;$display=@{};$truncated=$false
# The current read-only display-name lookup is identity assistance only; it does
# not sample or infer the historical state or requesting actor.
if($services.Count){try{$filter=($services|ForEach-Object {"Name='$_'"})-join ' OR ';foreach($row in @(Get-CimInstance Win32_Service -Filter $filter -Property Name,DisplayName -ErrorAction Stop)){if($row.Name -in $services){$display[$row.Name]=[string]$row.DisplayName}}}catch{}}
foreach($kind in @('scm','firewall','defender')){
 if($clock.ElapsedMilliseconds -ge 20000){$truncated=$true;$logs.Add([ordered]@{kind=$kind;state='budget_exhausted';records=0});continue}
 $query=QueryExistingEvents $kind $start $end;if($query.state -ceq 'capped'){$truncated=$true};$events=@($query.records);$logs.Add([ordered]@{kind=$kind;state=$query.state;records=[Math]::Min(64,$events.Count)})
 try{
  foreach($event in @($events|Select-Object -First 64)){
   if($clock.ElapsedMilliseconds -ge 20000){$truncated=$true;break}
   if($kind -ceq 'defender'){$defenderCount++;continue}
   try{$fields=ReadEventFields ($event.ToXml())}catch{$parseRefused++;continue}
   if($kind -ceq 'scm'){
    $matched=@($services|Where-Object {($fields.ContainsKey('param1') -and $fields['param1'] -ceq $_) -or ($display.ContainsKey($_) -and $fields.ContainsKey('param1') -and $display[$_] -ceq $fields['param1'])})
    if($matched.Count -eq 1){if($transitions.Count -ge 32){$truncated=$true;continue};$transitions.Add([ordered]@{name=$matched[0];event_id=[int]$event.Id;actor_class='not_available_in_SCM_transition_record'})}
   }else{
    $hash=if($fields.ContainsKey('RuleId')){RuleIdentityHash $fields['RuleId']}else{$null}
    if($null -ne $hash -and $hash -in $rules){
     if($firewall.Count -ge 32){$truncated=$true;continue}
     $image=if($fields.ContainsKey('ModifyingApplication')){ImageCategory $fields['ModifyingApplication']}else{[ordered]@{path_class='not_available';signer_class='not_sampled'}}
     $firewall.Add([ordered]@{rule_identity_sha256=$hash;event_id=[int]$event.Id;modifying_image_class=$image.path_class;post_test_image_signer_class=$image.signer_class})
    }
   }
  }
 }finally{foreach($event in $events){$event.Dispose()}}
}
WriteSafe $Report ([ordered]@{schema=1;scope='existing_local_events_only';logs=$logs.ToArray();service_transition_events=$transitions.ToArray();matched_firewall_events=$firewall.ToArray();defender_event_count=$defenderCount;parse_refused=$parseRefused;elapsed_ms=[int]$clock.ElapsedMilliseconds;configuration_changed=$false;actor_absence_is_not_proof_of_absence=$true;client_or_workflow_accepted=$false;observation_truncated=$truncated})
