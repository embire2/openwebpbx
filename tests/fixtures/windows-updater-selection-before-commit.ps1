# Exact source807285037: SCM selection ran before durable upgrade completion.
if(!$existing){
 New-Service -Name OpenWebPBXUpdater -BinaryPathName ('"'+$executable+'"') -DisplayName 'OpenWeb PBX Updates' -StartupType Automatic -DependsOn OpenWebPBX-Database|Out-Null
}else{& sc.exe config OpenWebPBXUpdater binPath= ('"'+$executable+'"') start= auto depend= OpenWebPBX-Database|Out-Null;if($LASTEXITCODE){throw 'The updater service slot could not be selected.'}}
& sc.exe failure OpenWebPBXUpdater reset= 86400 actions= restart/15000/restart/30000/restart/60000|Out-Null
& sc.exe failureflag OpenWebPBXUpdater 1|Out-Null
