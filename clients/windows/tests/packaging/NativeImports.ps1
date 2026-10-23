# SPDX-License-Identifier: AGPL-3.0-or-later
# Read-only DUMPBIN /IMPORTS inventory. This does not load a DLL or prove loader compatibility.
function ReadPackageNativeImports([string]$Text){
 if($Text.Length-gt 4MB -or $Text.Contains([char]0) -or $Text-match '(?i)<invalid|\b(?:fatal error|warning LNK|error LNK)'){throw 'Native import output is invalid or exceeds its bound.'}
 $normal=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$delay=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $section=$null;$normalHeaders=0;$delayHeaders=0;$types=0;$summaries=0;$descriptors=0
 foreach($line in $Text -split "`r?`n"){
  if($line-match '^File Type: (DLL|EXECUTABLE IMAGE)\s*$'){$types++;continue}
  if($line-match '^  Section contains the following imports:\s*$'){$normalHeaders++;$section='normal';continue}
  if($line-match '^  Section contains the following delay load imports:\s*$'){$delayHeaders++;$section='delay';continue}
  if($line-match '^  Summary\s*$'){$summaries++;$section=$null;continue}
  if($line-match '^    ([A-Za-z0-9_+.-]{1,160}\.dll)\s*$'){
   $name=$Matches[1].ToLowerInvariant();if(!$section -or $name.Contains('..')){throw 'Native import name is outside a recognised descriptor section.'};$descriptors++;if($descriptors-gt 1024){throw 'Native import descriptors exceed their bound.'};if($section-ceq 'normal'){[void]$normal.Add($name)}else{[void]$delay.Add($name)}
  }elseif(($section -and $line-match '(?i)^\s*\S.*\.dll\s*$') -or $line-match '(?i)^    \S.*\.dll\s*$' -or $line-match '^  Section contains '){throw 'Native import output contains an unsupported descriptor.'}
 }
 if($types-ne 1 -or $summaries-ne 1 -or $normalHeaders-gt 1 -or $delayHeaders-gt 1 -or ($normalHeaders-eq 1 -and $normal.Count-eq 0) -or ($delayHeaders-eq 1 -and $delay.Count-eq 0)){throw 'Native import output shape differs.'}
 [ordered]@{normal=@($normal|Sort-Object);delay=@($delay|Sort-Object);descriptor_count=$descriptors}
}
function GetPackageImportKind([string]$Name,[bool]$Bundled,[bool]$HostSystemFile){
 if($Name-cnotmatch '^[a-z0-9_+.-]{1,160}\.dll$' -or $Name.Contains('..')){throw 'An ordinary imported DLL basename is required.'}
 $crt=$Name-match '^(vcruntime[0-9]+(?:_[0-9]+)?|msvcp[0-9]+(?:_[a-z0-9]+)*|msvcr[0-9]+|concrt[0-9]+|vcomp[0-9]+|mfcm?[0-9]+[a-z0-9]*)d?\.dll$' -or $Name-ceq 'ucrtbased.dll'
 $debug=$Name-ceq 'ucrtbased.dll' -or ($crt -and $Name-match 'd\.dll$')
 if($debug){$kind='debug_crt_not_redistributable'}elseif($Bundled){$kind='bundled_candidate'}elseif($crt){$kind='external_vc_runtime'}elseif($Name-match '^(api-ms-win-|ext-ms-win-)'){$kind='api_set_contract_name'}elseif($HostSystemFile){$kind='host_system32_only'}else{$kind='unresolved'}
 [ordered]@{kind=$kind;vc_runtime=$crt;host_system32_present=$HostSystemFile}
}
