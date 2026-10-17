<?php
/** Controlled nspawn-only Call Me Back fixture; contains fictional identities only. */
if(PHP_SAPI!=='cli'||gethostname()!=='owpbx-native112-fresh'||trim(@file_get_contents('/run/systemd/container'))!=='systemd-nspawn')exit(2);
require dirname(__DIR__).'/resources/require.php';
$path=$argv[2]??'';if(!preg_match('~^/tmp/openweb-trunk-check-cmb-[a-f0-9]{12}\.json$~D',$path))throw new RuntimeException('Owned callback fixture path required.');
$f=json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR);$db=$database->db;$q=function($sql,$args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return$s;};
if($q('select domain_name from v_domains where domain_uuid=?',[$f['domain']])->fetchColumn()!==$f['realm']||!preg_match('/^carrier-check-[a-f0-9]{12}\.invalid$/D',$f['realm']))throw new RuntimeException('Owned tenant identity changed.');
$_SESSION=['authorized'=>true,'user_uuid'=>uuid(),'domain_uuid'=>$f['domain'],'domain_name'=>$f['realm']];
$action=$argv[1]??'';
if($action==='setup'){
 foreach($f['gateway_ids']as$g){$r=$q('select proxy,register from v_gateways where domain_uuid=? and gateway_uuid=?',[$f['domain'],$g])->fetch(PDO::FETCH_ASSOC);if(!$r||$r['register']||!preg_match('/^127\.0\.0\.1:[0-9]{4,5}$/D',$r['proxy']))throw new RuntimeException('External provider forbidden in this fixture.');}
 $admin=new pbx_admin($db);$admin->save('outbound','new',['name'=>'Fictional separate destination','prefix'=>'0820000002','lengths'=>'10','routes'=>[['trunk_id'=>$f['trunks'][1],'strip'=>'0','prepend'=>'']]]);$admin->save('outbound','new',['name'=>'Fictional callback external','prefix'=>'0','lengths'=>'10','routes'=>[['trunk_id'=>$f['trunks'][0],'strip'=>'0','prepend'=>'']]]);
 $c=$admin->config();$incoming=null;foreach($c['inbound_rules']as$r)if($r['number']==='999100001')$incoming=$r['rule_id'];if(!$incoming)throw new RuntimeException('Fixture incoming rule missing.');
 $f['cmb_service']=uuid();$f['cmb_account']=uuid();$f['cmb_identity']='8001015009087';$f['cmb_cli']='+27820000001';$f['cmb_destination']='0820000002';
 $key=file_get_contents(pbx_paths::key());$tenant=hash_hmac('sha256',"openweb-call-me-back-id/v1\0".$f['domain'],$key,true);$proof=hash_hmac('sha256',$f['cmb_identity'],$tenant);unset($key,$tenant);
 $dir=pbx_paths::storage().'/openwebpbx/call-me-back/'.$f['cmb_service'];mkdir($dir,0750,true);foreach([pbx_paths::storage().'/openwebpbx',pbx_paths::storage().'/openwebpbx/call-me-back']as$parent){chown($parent,33);chgrp($parent,33);}copy('/root/cmb-work/tenant-greeting.wav',$dir.'/greeting.wav');chown($dir,33);chgrp($dir,33);chown($dir.'/greeting.wav',33);chgrp($dir.'/greeting.wav',33);chmod($dir.'/greeting.wav',0640);
 $q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,prompt_state,prompt_sha256,enabled) values(?,?,'Fictional OpenWeb',?,'1001','ready',?,true)",[$f['cmb_service'],$f['domain'],$incoming,hash_file('sha256',$dir.'/greeting.wav')]);
 $q("insert into v_pbx_cmb_accounts(account_uuid,domain_uuid,service_uuid,name,id_hmac,id_last4,total_seconds) values(?,?,?,'Fictional account',?,'9087',3600)",[$f['cmb_account'],$f['domain'],$f['cmb_service'],$proof]);
 file_put_contents($path,json_encode($f,JSON_THROW_ON_ERROR));chmod($path,0600);echo "Fictional callback tenant ready.\n";exit;
}
if($action==='lock_answer'){
 $db->beginTransaction();$q('select request_uuid from v_pbx_cmb_requests where domain_uuid=? order by created_at desc limit 1 for update',[$f['domain']]);echo "LOCKED\n";flush();usleep(3000000);$db->commit();exit;
}
if($action==='status'){
 $a=$q('select used_seconds,reserved_seconds from v_pbx_cmb_accounts where domain_uuid=? and account_uuid=?',[$f['domain'],$f['cmb_account']])->fetch(PDO::FETCH_ASSOC);
 $r=$q('select request_uuid,state,call_uuid,bridge_uuid,reserved_seconds,used_seconds,last_result,connected_at from v_pbx_cmb_requests where domain_uuid=? order by created_at desc limit 1',[$f['domain']])->fetch(PDO::FETCH_ASSOC);echo json_encode(['account'=>$a,'request'=>$r],JSON_THROW_ON_ERROR);exit;
}
if($action==='reset'){
 $q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where domain_uuid=? and state in ('completed','failed','cancelled')",[$f['domain']]);echo "Cooldown of completed fictional requests advanced.\n";exit;
}
if($action==='quota'){
 $seconds=filter_var($argv[3]??'',FILTER_VALIDATE_INT,['options'=>['min_range'=>0,'max_range'=>3600]]);if($seconds===false)exit(2);
 $q('update v_pbx_cmb_accounts set total_seconds=used_seconds+? where domain_uuid=? and account_uuid=? and reserved_seconds=0',[$seconds,$f['domain'],$f['cmb_account']]);echo "Fictional account allowance changed.\n";exit;
}
if($action==='revoke'){$q('update v_pbx_cmb_bindings set revoked_at=now() where domain_uuid=? and account_uuid=?',[$f['domain'],$f['cmb_account']]);echo "Fictional binding revoked.\n";exit;}
if($action==='engine'){
 $cmd=$argv[3]??'';if(!preg_match('/^(?:status|show channels as json|show tasks as json|uuid_getvar [a-f0-9-]{36} [a-z_]+)$/D',$cmd))exit(2);echo event_socket::api($cmd);exit;
}
throw new RuntimeException('Unsupported fixture operation.');
