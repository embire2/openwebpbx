# Closed QA-only task failure metadata. No XML, arguments, identities or I/O.
function Read-QualificationTaskFailure($Record){
 if($Record-is [Collections.IDictionary]){$keys=@($Record.Keys)}elseif($Record-is [pscustomobject]){$keys=@($Record.PSObject.Properties.Name)}else{return $null}
 if($keys.Count-ne 3 -or @($keys|Where-Object {$_-cnotin 'schema','stage','task'}).Count -or ($Record.schema-isnot [int] -and $Record.schema-isnot [long]) -or $Record.schema-ne 1){return $null}
 $stages=@('inventory','existence','native_principal','xml_principal','new_enabled','new_action','new_schedule','new_boundary','new_owner','new_ace_kind','new_mutation_rights','schedule_count','schedule_boundary','original_contract')
 $tasks=@('inventory','OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-Onboarding','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
 if($Record.stage-isnot [string] -or $Record.stage-cnotin $stages -or $Record.task-isnot [string] -or $Record.task-cnotin $tasks){return $null}
 return @{schema=1;stage=$Record.stage;task=$Record.task}
}
function Set-QualificationTaskFailure($Failure,[string]$Stage,[string]$Task){
 try{$safe=Read-QualificationTaskFailure @{schema=1;stage=$Stage;task=$Task};if($safe){$Failure.Exception.Data['openweb_qa_task_failure']=$safe}}catch{}
}
function Assert-QualificationTaskRequirement([bool]$Value,[string]$Message,[string]$Stage,[string]$Task){
 try{Check $Value $Message}catch{$primary=$_;Set-QualificationTaskFailure $primary $Stage $Task;throw $primary}
}
