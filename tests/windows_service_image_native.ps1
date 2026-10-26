#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$OwnedRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSEdition-cne 'Desktop'-or $PSVersionTable.PSVersion.Major-ne 5-or $PSVersionTable.PSVersion.Minor-ne 1-or [IntPtr]::Size-ne 8-or $env:GITHUB_ACTIONS-cne 'true'-or $env:RUNNER_ENVIRONMENT-cne 'github-hosted'-or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Exact native owned SCM component context required.'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
if($os.Caption-notmatch 'Windows Server 2025'-or $os.ProductType-eq 1){throw 'Actual Windows Server2025 required.'}
$scope=Get-Item -LiteralPath $OwnedRoot -Force
if(!$scope.PSIsContainer-or $scope.FullName-match '\s'-or @(Get-ChildItem -LiteralPath $scope.FullName -Force).Count){throw 'Fresh whitespace-free owned scope required.'}
for($node=$scope;$node;$node=$node.Parent){if($node.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Ordinary owned scope required.'}}
$helper=Join-Path $SourceRoot 'tests/windows-health-updater-quiescence.ps1'
if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()-cne 'c9bce34d1c158a146cbca8885edc05339b989483be8e3ed8af92fbfd4447b459'){throw 'Exact reviewed image predicate required.'}
. $helper
$nonce=[Guid]::NewGuid().ToString('N');$name='OpenWebImageProbe_'+$nonce;$description='OpenWeb owned stopped image probe '+$nonce
$expected=Join-Path $scope.FullName 'owned-image.exe';$reportPath=Join-Path $scope.FullName 'native.safe.json'
$sourceImage=Join-Path $env:SystemRoot 'System32/where.exe';$sourceItem=Get-Item -LiteralPath $sourceImage -Force
if($sourceItem.PSIsContainer-or($sourceItem.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Ordinary stock metadata-only image required.'}
$sourceHash=(Get-FileHash -LiteralPath $sourceImage -Algorithm SHA256).Hash
$sc=Join-Path $env:SystemRoot 'System32/sc.exe';$controller=$null;$pin=$null;$created=$false;$primary=$null
$report=[ordered]@{schema=1;state='failed';scope='owned_disabled_stopped_SCM_image_representation_only';phase='absence';error_type='none';native_powershell='5.1';absence_before=$false;new_service_relation='unavailable';sc_config_relation='unavailable';explicit_unquoted_relation='unavailable';explicit_unquoted_finite_accepted=$false;original_quoted_guard_would_refuse=$false;creation_nonce_and_handle_bound=$false;service_always_disabled_stopped=$false;exact_sc_config_completed=$false;cleanup_definition_rechecked=$false;owned_service_absent_after=$false;service_handle_closed=$false;owned_image_removed=$false;stock_image_unchanged=$false;installed_PBX_or_historical_path_qualified=$false}
$failureOperation='absence';$ownedRowObservation=$null;$nativeSourcePath=$PSCommandPath
function Set-FailedScmObservation($Record) {
 try{
  if($null-eq $Record-or $Record.Exception-isnot[Exception]){return}
  $origin='unavailable';$line=0
  if($Record.InvocationInfo.ScriptName-ceq $nativeSourcePath-and $Record.InvocationInfo.ScriptLineNumber-gt 0-and $Record.InvocationInfo.ScriptLineNumber-le 10000){$origin='windows_service_image_native.ps1';$line=[int]$Record.InvocationInfo.ScriptLineNumber}
  $report.failure_observation=[ordered]@{schema=1;operation=$failureOperation;source_name=$origin;source_line=$line;hresult=[int]$Record.Exception.HResult;owned_sample=$ownedRowObservation}
 }catch{}
}
function OwnRow {
 if($name-cnotmatch '^OpenWebImageProbe_[a-f0-9]{32}$'){throw 'Owned name required.'}
 $rows=@(Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop)
 try{
  $script:ownedRowObservation=[ordered]@{count=$(if($rows.Count-eq 0){'none'}elseif($rows.Count-eq 1){'single'}else{'multiple'});name_matches=$null;description_matches=$null;display_matches=$null;system_account=$null;disabled=$null;stopped=$null;pid_zero=$null;finite_image=$null;image_relation='unavailable'}
  if($rows.Count-eq 1){$sample=$rows[0];$script:ownedRowObservation=[ordered]@{count='single';name_matches=[bool]($sample.Name-ceq $name);description_matches=[bool]($sample.Description-ceq $description);display_matches=[bool]($sample.DisplayName-ceq $description);system_account=[bool]($sample.StartName-cin 'LocalSystem','NT AUTHORITY\SYSTEM');disabled=[bool]($sample.StartMode-ceq 'Disabled');stopped=[bool]($sample.State-ceq 'Stopped');pid_zero=[bool]($sample.ProcessId-eq 0);finite_image=[bool](Test-HealthUpdaterServiceImage $sample.PathName $expected);image_relation=(Get-HealthUpdaterImageRelation $sample.PathName $expected)}}
 }catch{$script:ownedRowObservation=$null}
 if($rows.Count-ne 1){throw 'Single owned service required.'};$row=$rows[0]
 if($row.Name-cne $name-or $row.Description-cne $description-or $row.DisplayName-cne $description-or $row.StartName-cnotin 'LocalSystem','NT AUTHORITY\SYSTEM'-or $row.StartMode-cne 'Disabled'-or $row.State-cne 'Stopped'-or $row.ProcessId-ne 0-or !(Test-HealthUpdaterServiceImage $row.PathName $expected)){throw 'Owned stopped definition changed.'}
 return $row
}
try{
 if(@(Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop).Count){throw 'Owned service collision; nothing may be adopted.'}
 $report.absence_before=$true;$report.phase='copy';$failureOperation='copy'
 Copy-Item -LiteralPath $sourceImage -Destination $expected -ErrorAction Stop
 if((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash-cne $sourceHash){throw 'Owned image copy differs.'}
 $report.phase='new_service'
 $failureOperation='new_service'
 $controller=New-Service -Name $name -BinaryPathName ('"'+$expected+'"') -DisplayName $description -Description $description -StartupType Disabled -ErrorAction Stop
 $created=$true
 $failureOperation='controller_type'
 if($controller-isnot [ServiceProcess.ServiceController]){throw 'Actual owned service controller required.'}
 $failureOperation='service_handle'
 $pin=$controller.ServiceHandle
 $failureOperation='service_handle_validation'
 if(!$pin-or $pin.IsInvalid-or $pin.IsClosed){throw 'Original owned service handle unavailable.'}
 $failureOperation='own_row'
 $row=OwnRow;$report.creation_nonce_and_handle_bound=$true;$report.new_service_relation=Get-HealthUpdaterImageRelation $row.PathName $expected
 $report.phase='sc_config'
 if($pin.IsInvalid-or $pin.IsClosed){throw 'Original service handle changed before selection.'}
 $failureOperation='own_row'
 $null=OwnRow
 $failureOperation='sc_config'
 & $sc config $name binPath= ('"'+$expected+'"')|Out-Null
 if($LASTEXITCODE){throw 'Owned native sc config failed.'}
 $report.exact_sc_config_completed=$true;$failureOperation='own_row';$row=OwnRow;$report.sc_config_relation=Get-HealthUpdaterImageRelation $row.PathName $expected
 $report.phase='explicit_unquoted'
 if($pin.IsInvalid-or $pin.IsClosed){throw 'Original handle changed before unquoted selection.'}
 $failureOperation='own_row'
 $null=OwnRow
 $failureOperation='sc_config'
 & $sc config $name binPath= $expected|Out-Null
 if($LASTEXITCODE){throw 'Explicit owned unquoted selection failed.'}
 $failureOperation='own_row'
 $row=OwnRow;$report.explicit_unquoted_relation=Get-HealthUpdaterImageRelation $row.PathName $expected
 if($report.explicit_unquoted_relation-cne 'unquoted_expected'-or !(Test-HealthUpdaterServiceImage $row.PathName $expected)-or $row.PathName-ieq ('"'+$expected+'"')){throw 'Actual finite unquoted distinction was not proved.'}
 $report.explicit_unquoted_finite_accepted=$true;$report.original_quoted_guard_would_refuse=$true
 $report.service_always_disabled_stopped=$true;$report.phase='cleanup';$failureOperation='cleanup'
}catch{$primary=$_;$report.error_type=$_.Exception.GetType().Name;Set-FailedScmObservation $_;throw}
finally{
 try{
  if($created){
   if(!$pin-or $pin.IsInvalid-or $pin.IsClosed){throw 'Pinned original ownership required for deletion.'}
   $failureOperation='own_row_cleanup'
   $null=OwnRow;$report.cleanup_definition_rechecked=$true;$failureOperation='cleanup'
   & $sc delete $name|Out-Null
   if($LASTEXITCODE){throw 'Owned service deletion failed.'}
   $pin.Dispose()
   if(!$pin.IsClosed){throw 'Original service handle did not close.'};$report.service_handle_closed=$true
   $controller.Dispose();$controller=$null
   $end=[Diagnostics.Stopwatch]::StartNew()
   do{$remaining=@(Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop);if(!$remaining.Count){break};if($end.ElapsedMilliseconds-ge 10000){throw 'Owned service absence unproved.'};Start-Sleep -Milliseconds 100}while($true)
   $report.owned_service_absent_after=$true
   if((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash-cne $sourceHash){throw 'Owned copy changed before removal.'}
   Remove-Item -LiteralPath $expected -ErrorAction Stop;$report.owned_image_removed=!(Test-Path -LiteralPath $expected)
   $report.stock_image_unchanged=(Get-FileHash -LiteralPath $sourceImage -Algorithm SHA256).Hash-ceq $sourceHash
  }
 }catch{if($null-eq $primary){$primary=$_;$report.error_type=$_.Exception.GetType().Name;Set-FailedScmObservation $_}else{$primary.Exception.Data['owned_service_cleanup_refused']=$true}}
 finally{
  try{if($pin-and !$pin.IsClosed){$pin.Dispose()};if($controller){$controller.Dispose()}}catch{if($null-eq $primary){$primary=$_;$report.error_type=$_.Exception.GetType().Name;Set-FailedScmObservation $_}else{$primary.Exception.Data['owned_handle_close_refused']=$true}}
  if($pin-and$pin.IsClosed){$report.service_handle_closed=$true}
 }
 if($null-eq $primary-and$created-and$report.owned_service_absent_after-and$report.service_handle_closed-and$report.owned_image_removed-and$report.stock_image_unchanged){$report.state='passed';$report.phase='complete'}
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 4 -Compress));if($bytes.Length-gt 8192){throw 'Bounded native report required.'};$file=[IO.File]::Open($reportPath,'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}}catch{if($null-eq $primary){throw}}
}
if($null-ne $primary){throw $primary}
if($report.state-cne 'passed'){throw 'No native SCM image result qualified.'}
