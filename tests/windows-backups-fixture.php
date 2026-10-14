<?php
/** Explicit disposable-runner fixture. Never a production repair helper. */
if(PHP_SAPI!=='cli'||getenv('OPENWEB_WINDOWS_BACKUP_TEST')!=='1')exit(2);
require 'C:/OpenWebPBX/web/resources/require.php';
$path=$argv[2]??'';$root=pbx_paths::state().'/backup-qualification';
if(!str_starts_with(str_replace('\\','/',$path),$root.'/')||is_link($path))throw new RuntimeException('Private qualification input required.');
$s=json_decode(file_get_contents($path),true,512,JSON_THROW_ON_ERROR);$db=$database->db;
$q=function($sql,$args=[])use($db){$p=$db->prepare($sql);$p->execute($args);return $p;};
$action=$argv[1]??'';
if($action==='create'){
 foreach(['v_extensions','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_recordings','v_voicemail_messages'] as $table)if((int)$q('select count(*) from '.$table)->fetchColumn()!==0)throw new RuntimeException('A separate empty factory is required.');
 if((int)$q('select count(*) from v_users')->fetchColumn()!==1||(int)$q('select count(*) from v_domains')->fetchColumn()!==1)throw new RuntimeException('An empty factory is required.');
 $factory_admin=$q('select user_uuid,domain_uuid from v_users where username=?',[$s['admin_email']])->fetch(PDO::FETCH_ASSOC);
 $user_uuid=$factory_admin['user_uuid']??'';
 if(!is_uuid($user_uuid))throw new RuntimeException('The factory administrator is unavailable.');
 unset($_SESSION['permissions']);
 $native_permissions=(new permissions($database,$factory_admin['domain_uuid'],$user_uuid))->get_permissions();
 if(empty($native_permissions['pbx_service_create'])||empty($native_permissions['pbx_tenant_manage']))throw new RuntimeException('The real factory administrator permissions are required.');
 $domain_uuid=uuid();$realm='backup-native-'.bin2hex(random_bytes(6)).'.invalid';
 $_SESSION=['authorized'=>true,'user_uuid'=>$user_uuid,'domain_uuid'=>$domain_uuid,'domain_name'=>$realm,'user'=>['domain_uuid'=>$factory_admin['domain_uuid']],'permissions'=>$native_permissions];
 $q('insert into v_domains(domain_uuid,domain_name,domain_enabled,domain_description) values(?,?,true,?)',[$domain_uuid,$realm,'Owned native backup qualification']);
 $s['fixture_domain']=$domain_uuid;$s['fixture_realm']=$realm;file_put_contents($path,json_encode($s,JSON_THROW_ON_ERROR));
 file_put_contents($root.'/owned-fixture.json',json_encode(['fixture_domain'=>$domain_uuid,'fixture_realm'=>$realm],JSON_THROW_ON_ERROR));
 $admin=new pbx_admin($db);$db->beginTransaction();$admin->initialize($realm);$db->commit();
 foreach(['8100','8101'] as $number)$admin->save('user','new',['number'=>$number,'name'=>'Native Backup Fixture '.$number,'enabled'=>'1','profile'=>'Available']);
 $admin->save('trunk','new',['name'=>'Disabled loopback backup fixture','host'=>'127.0.0.1','authentication'=>'ip','register'=>'0','enabled'=>'','allowed_ips'=>'127.0.0.1','codecs'=>'PCMU,PCMA']);
 $admin->save('queue','new',['number'=>'8190','name'=>'Owned backup queue','members'=>['8100','8101'],'timeout'=>'30','ring_timeout'=>'10','wrap_up'=>'0','callback_mode'=>'request','callback_after'=>'10','callback_attempts'=>'1','callback_prefix'=>'','destination'=>'None:']);
 echo "Owned native PBX fixture created.\n";exit;
}
$domain=$s['fixture_domain']??'';$realm=$s['fixture_realm']??'';
if(!is_uuid($domain)||!preg_match('/^backup-native-[a-f0-9]{12}\.invalid$/D',$realm))throw new RuntimeException('Fixture ownership mismatch.');
$actual=$q('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn();
if($action==='clear-held'&&$actual===false){
 foreach($q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN) as $table)if(preg_match('/^v_[a-z0-9_]+$/D',$table)&&(int)$q('select count(*) from '.$table.' where domain_uuid=?',[$domain])->fetchColumn()!==0)throw new RuntimeException('Owned rows remain without their fixture domain.');
 echo "Owned fixture was already removed.\n";exit;
}
if($actual!==$realm)throw new RuntimeException('Fixture ownership mismatch.');
if(in_array($action,['clear','clear-held'],true)){
 $agents=$q('select call_center_agent_uuid from v_call_center_agents where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN);
 if($action==='clear'){
  foreach($agents as $agent)if(is_uuid($agent)){event_socket::api('callcenter_config tier del 8190@'.$realm.' '.$agent);event_socket::api('callcenter_config agent del '.$agent);}
  event_socket::api('callcenter_config queue unload 8190@'.$realm);
  foreach($q('select gateway_uuid from v_gateways where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN) as $id)if(is_uuid($id))event_socket::api('sofia profile external killgw '.$id);
 }
 $db->beginTransaction();
 foreach($q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN) as $table)if($table!=='v_domains'&&preg_match('/^v_[a-z0-9_]+$/D',$table))$q('delete from '.$table.' where domain_uuid=?',[$domain]);
 $q('delete from v_domains where domain_uuid=?',[$domain]);$db->commit();
 $cache=new cache;foreach(['dialplan:'.$realm,'dialplan:ingress@'.$realm,'configuration:callcenter.conf',gethostname().':configuration:callcenter.conf','configuration:acl.conf',gethostname().':configuration:acl.conf',gethostname().':configuration:sofia.conf','dialplan:openweb-incoming:'.gethostname()] as $name)$cache->delete($name);
 foreach(['8100','8101','ow-8100','ow-8101'] as $number)$cache->delete('directory:'.$number.'@'.$realm);
 if($action==='clear'){event_socket::api('reloadxml');event_socket::api('reloadacl');}echo "Owned fixture rows removed; factory is ready for restore.\n";exit;
}
throw new RuntimeException('Unknown fixture operation.');
