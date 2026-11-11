<?php
/** Exercise actual PostgreSQL ownership and contact mutations in a disposable schema. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/require.php';
$db=$database->db;$schema='openweb_account26_'.bin2hex(random_bytes(6));$checks=0;
$q=function($sql,$in=[])use($db){$s=$db->prepare($sql);$s->execute($in);return $s;};
$ok=function($v,$m)use(&$checks){$checks++;if(!$v)throw new RuntimeException($m);};
$denied=function($fn,$m)use($ok){try{$fn();}catch(pbx_api_access_denied|pbx_staff_denied|pbx_core_access|OutOfBoundsException|InvalidArgumentException $e){$ok(true,$m);return;}$ok(false,$m);};
$as=function($id,$d){$_SESSION=['authorized'=>true,'user_uuid'=>$id,'domain_uuid'=>$d,'user'=>['domain_uuid'=>$d]];permissions::reset();};
try{
 $db->exec('create schema '.$schema);
 // Shadow every customer table: an omitted fixture cannot fall through to live data.
 $tables=$db->query("select tablename from pg_tables where schemaname='public' and tablename like 'v_%'")->fetchAll(PDO::FETCH_COLUMN);
 foreach($tables as $table){if(!preg_match('/^v_[a-z0-9_]+$/D',$table))throw new RuntimeException('Unexpected table');$db->exec('create table '.$schema.'.'.$table.' (like public.'.$table.' including all)');}
 $db->exec('set search_path to '.$schema.',public');
 $domain=uuid();$other=uuid();foreach([$domain,$other] as $d)$q("insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)",[$d,$d.'.fixture.invalid']);
 $users=[];$extensions=[];$config=['realm'=>$domain.'.fixture.invalid','timezone'=>'UTC','users'=>[],'trunks'=>[],'departments'=>[],'queues'=>[],'ring_groups'=>[],'receptionists'=>[],'contacts'=>[],'inbound_rules'=>[],'outbound_rules'=>[],'scripts'=>[]];
 foreach(array_keys(pbx_staff_access::roles()) as $i=>$role){$n=(string)(1000+$i);$uid=uuid();$eid=uuid();$users[$role]=$uid;$extensions[$role]=$eid;
  $q("insert into v_users(user_uuid,domain_uuid,username,user_enabled)values(?,?,?,true)",[$uid,$domain,$role.'@fixture.invalid']);
  $q("insert into v_extensions(extension_uuid,domain_uuid,extension,password,enabled)values(?,?,?,?,true)",[$eid,$domain,'auth-'.$n,'fixture-only-password']);
  $q('insert into v_pbx_staff_roles(staff_role_uuid,domain_uuid,user_uuid,extension_uuid,department_id,role,enabled)values(?,?,?,?,?,?,true)',[uuid(),$domain,$uid,$eid,'dept-a',$role]);
  $config['users'][$n]=['number'=>$n,'auth_id'=>'auth-'.$n,'extension_uuid'=>$eid,'name'=>$role,'enabled'=>true,'voicemail_enabled'=>false,'profile'=>'Available','queue_status'=>'LoggedIn','profiles'=>['Available'=>['queue_status'=>'1'],'Away'=>['queue_status'=>'0']]];
 }
 $config['users']['2000']=['number'=>'2000','auth_id'=>'foreign-auth','extension_uuid'=>uuid(),'name'=>'Other department','enabled'=>true];
 $config['departments']=[['number'=>'dept-a','name'=>'Department A','members'=>array_map(fn($n)=>['number'=>(string)$n],range(1000,1005))],['number'=>'dept-b','name'=>'Department B','publish_information'=>false,'members'=>[['number'=>'2000']]]];
 $config['contacts']=[['first_name'=>'Company','phone'=>'0123456789','owner'=>''],['first_name'=>'Foreign','phone'=>'0123456790','owner'=>'2000']];
 $q("insert into v_pbx_restore(domain_uuid,source_version,config,report)values(?,'account-fixture',?::jsonb,'{}')",[$domain,json_encode($config)]);
 $q("insert into v_pbx_restore(domain_uuid,source_version,config,report)values(?,'account-fixture',?::jsonb,'{}')",[$other,json_encode(['realm'=>$other.'.fixture.invalid','users'=>[]])]);
 $api=new pbx_reseller_api($db);$keys=new pbx_access_keys($db);$issued=[];
 foreach($users as $role=>$uid){$as($uid,$domain);$choice=$keys->choices();$ok($choice['account_only']&&$choice['default_domain']===$domain,'Staff key UI escaped its account');
  $key=$keys->create(['name'=>'Personal '.$role,'scopes'=>['me:read','me:write','keys:manage']]);$issued[$role]=$key;$auth='Bearer '.$key['token'];
  $me=$api->handle('GET','/me',[],$auth,'192.0.2.1');$ok($me['name']===$role&&count($me['roles'])===1,'Personal identity not derived from binding');
  $denied(fn()=>$api->handle('GET','/pbx/'.$domain.'/users',[],$auth,'192.0.2.1'),'Personal key accessed PBX administration');
  $denied(fn()=>$api->handle('GET','/instance/mail',[],$auth,'192.0.2.1'),'Personal key accessed global mail');
  $denied(fn()=>$api->handle('GET','/tenants',[],$auth,'192.0.2.1'),'Personal key enumerated tenants');
  $denied(fn()=>$api->handle('POST','/me/contacts/create',['first_name'=>'Wrong identity','phone'=>'0123456789','extension_uuid'=>$extensions['user']],$auth,'192.0.2.1'),'Personal endpoint accepted client identity');
  $as($uid,$domain);$denied(fn()=>$keys->create(['name'=>'Foreign','domain_uuid'=>$other,'scopes'=>['me:read']]),'Staff created foreign domain key');
  $denied(fn()=>$keys->create(['name'=>'Mixed','scopes'=>['me:read','pbx:write']]),'Mixed key escalated to administrator');
  $denied(fn()=>$keys->create(['name'=>'Admin','domain_uuid'=>$domain,'scopes'=>['pbx:read']]),'Staff minted administrator key');
  $personal=$api->handle('POST','/me/contacts/create',['first_name'=>'Mine','phone'=>'0123456700'],$auth,'192.0.2.1');
  $visible=$api->handle('GET','/me/contacts',[],$auth,'192.0.2.1');$ok(count($visible)===2,'Personal contacts exposed another user contacts');
  $denied(fn()=>$api->handle('POST','/me/contacts/legacy-0/delete',['confirm_delete'=>true],$auth,'192.0.2.1'),'User deleted company contact');
  $denied(fn()=>$api->handle('POST','/me/contacts/'.$personal['id'],['phone'=>'0123456701','owner'=>'2000'],$auth,'192.0.2.1'),'User reassigned contact to another extension');
  $api->handle('POST','/me/contacts/'.$personal['id'].'/delete',['confirm_delete'=>true],$auth,'192.0.2.1');$ok(count($api->handle('GET','/me/contacts',[],$auth,'192.0.2.1'))===1,'Own contact deletion failed');
  $denied(fn()=>$api->handle('POST','/me/phone-qr-reset',['confirmed'=>true],$auth,'192.0.2.1'),'Key without credentials replaced QR');
  $denied(fn()=>$api->handle('POST','/me/call-control',['call'=>uuid(),'operation'=>'end'],$auth,'192.0.2.1'),'Noncalling key controlled call');
  if($role==='user'){$as($uid,$domain);$denied(fn()=>$keys->create(['name'=>'Staff escalation','scopes'=>['staff:write']]),'User minted department write key');}
  else{$as($uid,$domain);$staff=$keys->create(['name'=>'Scoped '.$role,'scopes'=>['staff:read','staff:write','staff:calls']]);$sa='Bearer '.$staff['token'];
   $view=$api->handle('GET','/staff/overview',[],$sa,'192.0.2.1');$ok(!isset($view['users']['2000']),'Staff overview crossed department');
   $denied(fn()=>$api->handle('POST','/staff/users/2000',['name'=>'Forbidden'],$sa,'192.0.2.1'),'Staff edited another department user');
   $denied(fn()=>$api->handle('POST','/staff/roles/grant',['number'=>'2000','department'=>'dept-b','role'=>'owner','email'=>'bad@fixture.invalid'],$sa,'192.0.2.1'),'Department key granted foreign owner');
   $denied(fn()=>$api->handle('GET','/pbx/'.$domain.'/users',[],$sa,'192.0.2.1'),'Department key bypassed explicit staff filtering');
   $denied(fn()=>$api->handle('GET','/staff/queue-report',['days'=>91],$sa,'192.0.2.1'),'Queue report accepted more than 90 days');
   $denied(fn()=>$api->handle('GET','/staff/queue-report',['days'=>true],$sa,'192.0.2.1'),'Queue report accepted a boolean duration');
  }
 }
 $as($users['user'],$domain);$parent=$issued['user'];$child=$api->handle('POST','/keys',['name'=>'Read child','scopes'=>['me:read']],'Bearer '.$parent['token'],'192.0.2.1');$ok(isset($child['token']),'Personal delegation failed');
 $denied(fn()=>$api->handle('POST','/keys',['name'=>'Escalate','scopes'=>['staff:read']],'Bearer '.$parent['token'],'192.0.2.1'),'Personal parent delegated department rights');
 $as($users['user'],$domain);$keys->revoke($parent['key_uuid']);$denied(fn()=>$api->handle('GET','/me',[],'Bearer '.$child['token'],'192.0.2.1'),'Personal child survived parent revocation');
 $q('update v_pbx_staff_roles set enabled=false where user_uuid=?',[$users['manager']]);$denied(fn()=>$keys->authenticate('Bearer '.$issued['manager']['token'],'192.0.2.1'),'Revoked staff retained personal key');
 $q('update v_pbx_staff_roles set enabled=true where user_uuid=?',[$users['manager']]);$q("update v_users set user_enabled='false' where user_uuid=?",[$users['manager']]);$denied(fn()=>$keys->authenticate('Bearer '.$issued['manager']['token'],'192.0.2.1'),'Disabled web user retained API');
 $as($users['user'],$domain);$contacts=new pbx_contacts($db);$contacts->save('legacy-0',['confirm_delete'=>true],true);$remaining=$contacts->listing();$ok(count($remaining)===1&&$remaining[0]['id']==='legacy-1','Deleting an earlier imported contact changed another contact identity');
 foreach(pbx_account_api::ROUTES as $route=>$definition){$path=str_replace('{id}',uuid(),$route);$ok(pbx_account_api::route($path)!==null,'Published account route missing dispatcher');}
 echo 'PASS '.$checks." PostgreSQL personal/department API controls; no customer rows or calls changed.\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
