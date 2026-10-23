<?php
require __DIR__.'/windows-native-cleanup-rows.php';
$old=getenv('GITHUB_RUN_ID');putenv('GITHUB_RUN_ID=fictional-owned-run');$checks=0;
function check_scope(bool$value):void{global$checks;if(!$value)throw new RuntimeException('Owned cleanup scope control failed.');$checks++;}
$scope=str_repeat('a',24);$s=['schema'=>1,'scope'=>$scope,'restore_server'=>true,'run_id'=>'fictional-owned-run','service_name'=>'Fictional Native '.$scope,'factory_admin'=>['user_uuid'=>'20000000-0000-0000-0000-000000000001','domain_uuid'=>'20000000-0000-0000-0000-000000000002']];
try{
 check_scope(windows_native_cleanup_scope($s,$scope,true)===[]);
 $failed=false;try{windows_native_cleanup_scope($s,$scope);}catch(InvalidArgumentException){$failed=true;}check_scope($failed);
 $s['owned']=['domain_uuid'=>'30000000-0000-0000-0000-000000000001','home_domain_uuid'=>'30000000-0000-0000-0000-000000000002','tenant_uuid'=>'30000000-0000-0000-0000-000000000003','domain_name'=>'pbx-aaaaaaaaaaaa.example.invalid'];
 check_scope(count(windows_native_cleanup_scope($s,$scope))===2);check_scope(windows_native_cleanup_scope($s,$scope)===windows_native_cleanup_scope($s,$scope,true));
 foreach(['schema','scope','restore_server','run_id','service_name','factory_admin','owned']as$field){$copy=$s;$copy[$field]=null;foreach([false,true]as$pre){$failed=false;try{windows_native_cleanup_scope($copy,$scope,$pre);}catch(InvalidArgumentException){$failed=true;}check_scope($failed);}}
 foreach(['domain_uuid','home_domain_uuid','tenant_uuid','domain_name']as$field){$copy=$s;$copy['owned'][$field]='FOREIGN';$failed=false;try{windows_native_cleanup_scope($copy,$scope,true);}catch(InvalidArgumentException){$failed=true;}check_scope($failed);}
 $copy=$s;$copy['owned']['home_domain_uuid']=$s['owned']['domain_uuid'];$failed=false;try{windows_native_cleanup_scope($copy,$scope);}catch(InvalidArgumentException){$failed=true;}check_scope($failed);
 $copy=$s;$copy['owned']['home_domain_uuid']=$s['factory_admin']['domain_uuid'];$failed=false;try{windows_native_cleanup_scope($copy,$scope);}catch(InvalidArgumentException){$failed=true;}check_scope($failed);
 echo 'PASS '.$checks.' actual cleanup owned/pre-owned scope/type/foreign-identity controls; no PBX or database contacted',PHP_EOL;
}finally{putenv($old===false?'GITHUB_RUN_ID':'GITHUB_RUN_ID='.$old);}
