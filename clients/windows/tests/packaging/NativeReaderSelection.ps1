# SPDX-License-Identifier: AGPL-3.0-or-later
# Observation only. This does not select a tool, execute DUMPBIN or establish trust.
function GetPackageNativeReaderObservation([object[]]$Candidates){
 $rows=@();$count=$Candidates.Count
 if($count-le 16){foreach($candidate in $Candidates){
  $value=$candidate.VersionInfo.FileVersion;$originalPatternMatches=$value-cmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$';$shape='other';$numeric=$null
  if($null-eq $value){$shape='missing'}elseif($value-isnot [string]){$shape='non_string'}elseif($value.Length-eq 0){$shape='empty'}elseif($value.Length-gt 256){$shape='oversized'}elseif($originalPatternMatches){$shape='four_component_numeric';try{$version=[version]$value;$numeric=@($version.Major,$version.Minor,$version.Build,$version.Revision)}catch{}}
  elseif($value-cmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[^0-9.]'){$shape='numeric_prefix_with_suffix'}
  $parts=@($candidate.VersionInfo.FileMajorPart,$candidate.VersionInfo.FileMinorPart,$candidate.VersionInfo.FileBuildPart,$candidate.VersionInfo.FilePrivatePart);foreach($part in $parts){if($part-isnot [int] -or $part-lt 0 -or $part-gt 65535){throw 'Native reader resource-version parts differ.'}}
  $rows+=,[ordered]@{index=$rows.Count;file_version_shape=$shape;matches_original_pattern=[bool]$originalPatternMatches;parsed_numeric_version=$numeric;resource_version_parts=$parts;file_reparse_point=[bool]($candidate.Attributes-band [IO.FileAttributes]::ReparsePoint);ordinary_ancestry_evaluated=$false;signature_evaluated=$false}
 }}
 [ordered]@{schema=1;producer='PackageNativeReaderSelection';candidate_count=[Math]::Min($count,17);count_capped=($count-gt 16);candidates=$rows;selection_changed=$false;tool_executed=$false}
}
function ReadPackageNativeReaderObservation([string]$Text){
 if($Text.Length-gt 16384){throw 'Native reader observation exceeds its bound.'}
 $document=[Text.Json.JsonDocument]::Parse($Text);try{
  function UniqueReaderJson($Element){if($Element.ValueKind-eq [Text.Json.JsonValueKind]::Object){$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $Element.EnumerateObject()){if(!$seen.Add($entry.Name)){throw 'Native reader observation repeats a field.'};UniqueReaderJson $entry.Value}}elseif($Element.ValueKind-eq [Text.Json.JsonValueKind]::Array){foreach($entry in $Element.EnumerateArray()){UniqueReaderJson $entry}}};UniqueReaderJson $document.RootElement
 }finally{$document.Dispose()}
 $v=$Text|ConvertFrom-Json -AsHashtable
 function ReaderFields($Value,[string[]]$Names){if($Value-isnot [Collections.IDictionary] -or (@($Value.Keys|Sort-Object)-join ',')-cne (@($Names|Sort-Object)-join ',')){throw 'Native reader observation fields differ.'}}
 ReaderFields $v @('schema','producer','candidate_count','count_capped','candidates','selection_changed','tool_executed')
 if($v.schema-isnot [long] -or $v.schema-ne 1 -or $v.producer-cne 'PackageNativeReaderSelection' -or $v.candidate_count-isnot [long] -or $v.candidate_count-lt 0 -or $v.candidate_count-gt 17 -or $v.count_capped-isnot [bool] -or $v.count_capped-ne ($v.candidate_count-eq 17) -or $v.candidates-isnot [array] -or $v.candidates.Count-ne $(if($v.count_capped){0}else{$v.candidate_count}) -or $v.selection_changed-isnot [bool] -or $v.selection_changed -or $v.tool_executed-isnot [bool] -or $v.tool_executed){throw 'Native reader observation scope differs.'}
 for($index=0;$index-lt $v.candidates.Count;$index++){$row=$v.candidates[$index];ReaderFields $row @('index','file_version_shape','matches_original_pattern','parsed_numeric_version','resource_version_parts','file_reparse_point','ordinary_ancestry_evaluated','signature_evaluated')
  if($row.index-isnot [long] -or $row.index-ne $index -or $row.file_version_shape-cnotin @('other','missing','non_string','empty','oversized','four_component_numeric','numeric_prefix_with_suffix')){throw 'Native reader candidate shape differs.'}
  foreach($name in @('matches_original_pattern','file_reparse_point','ordinary_ancestry_evaluated','signature_evaluated')){if($row[$name]-isnot [bool]){throw 'Native reader candidate requires typed observations.'}}
  if($row.ordinary_ancestry_evaluated -or $row.signature_evaluated -or ($row.file_version_shape-ceq 'four_component_numeric' -and !$row.matches_original_pattern) -or ($row.file_version_shape-notin @('four_component_numeric','oversized','non_string') -and $row.matches_original_pattern)){throw 'Native reader candidate scope differs.'}
  foreach($name in @('parsed_numeric_version','resource_version_parts')){$parts=$row[$name];if($name-ceq 'parsed_numeric_version' -and $null-eq $parts){continue};if($parts-isnot [array] -or $parts.Count-ne 4){throw 'Native reader numeric version shape differs.'};foreach($part in $parts){if($part-isnot [long] -or $part-lt 0 -or $part-gt $(if($name-ceq 'resource_version_parts'){65535}else{[int]::MaxValue})){throw 'Native reader numeric version differs.'}}}
  if($null-ne $row.parsed_numeric_version -and $row.file_version_shape-cne 'four_component_numeric'){throw 'Native reader numeric parse was not observed.'}
 };$v
}
