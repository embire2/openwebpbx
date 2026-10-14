<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Fictional hosted-runner fixture only. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||getenv('OPENWEB_WINDOWS_NATIVE_TEST')!=='1'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')exit(2);
set_exception_handler(static function(Throwable $e): void {fwrite(STDERR,"Private Windows native fixture failed.\n");exit(1);});
require 'C:/OpenWebPBX/web/resources/require.php';
$path=str_replace('\\','/',$argv[2]??'');$root=pbx_paths::state().'/native-qualification/';
if(!str_starts_with($path,$root)||is_link($path)||!is_file($path))throw new RuntimeException('Private fixture input required.');
$s=json_decode(file_get_contents($path),true,128,JSON_THROW_ON_ERROR);$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
if(($s['schema']??0)!==1||($s['restore_server']??false)!==true||!preg_match('/^[a-f0-9]{24}$/D',$s['scope']??''))throw new RuntimeException('Explicit disposable factory required.');
$q=static function(string $sql,array $args=[])use($db):PDOStatement{$p=$db->prepare($sql);foreach(array_values($args) as $i=>$value)$p->bindValue($i+1,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));$p->execute();return $p;};
$save=static function()use(&$s,$path):void{file_put_contents($path,json_encode($s,JSON_THROW_ON_ERROR|JSON_PRETTY_PRINT));};
$identity=static function()use($q):array{return ['users'=>$q('select user_uuid,domain_uuid,username,user_email,password,salt,user_enabled from v_users order by user_uuid')->fetchAll(PDO::FETCH_ASSOC),'domains'=>$q('select * from v_domains order by domain_uuid')->fetchAll(PDO::FETCH_ASSOC)];};
$factory=static function()use($q):void{
 foreach(['v_extensions','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_recordings','v_voicemail_messages','v_gateways','v_call_center_queues','v_pbx_jobs','v_pbx_media'] as $t)if((int)$q('select count(*) from '.$t)->fetchColumn()!==0)throw new RuntimeException('A separate empty factory is required.');
 if((int)$q('select count(*) from v_users')->fetchColumn()!==1||(int)$q('select count(*) from v_domains')->fetchColumn()!==1)throw new RuntimeException('A separate empty factory is required.');
};
$restoreGlobals=static function()use(&$s,$q):void{
 foreach(['v_default_settings'=>['email',$s['smtp_before']??[]],'v_sip_profile_settings'=>[null,$s['profiles_before']??[]],'v_pbx_mobile_push_config'=>[null,$s['push_before']??[]]] as $table=>[$category,$rows]){
  if($category)$q('delete from '.$table.' where default_setting_category=?',[$category]);else $q('delete from '.$table);
  foreach($rows as $r){$keys=array_keys($r);$q('insert into '.$table.'('.implode(',',$keys).') values('.implode(',',array_fill(0,count($keys),'?')).')',array_values($r));}
 }
};
$action=$argv[1]??'';
if($action==='baseline'){
 $factory();$admin=$q('select user_uuid,domain_uuid from v_users where username=?',[$s['admin_email']])->fetch(PDO::FETCH_ASSOC);if(!$admin)throw new RuntimeException('Factory administrator missing.');
 $s['baseline']=$identity();$s['factory_admin']=$admin;$s['smtp_before']=$q("select * from v_default_settings where default_setting_category='email' order by default_setting_uuid")->fetchAll(PDO::FETCH_ASSOC);
 $s['profiles_before']=$q('select * from v_sip_profile_settings order by sip_profile_setting_uuid')->fetchAll(PDO::FETCH_ASSOC);
 $s['push_before']=$q('select * from v_pbx_mobile_push_config')->fetchAll(PDO::FETCH_ASSOC);
 $s['drafts_before']=$q('select draft_uuid from v_pbx_setup_drafts')->fetchAll(PDO::FETCH_COLUMN);$save();echo "{\"factory_empty\":true}\n";exit;
}
if(!isset($s['baseline']))throw new RuntimeException('Original factory inventory is required.');
if($action==='discover'||$action==='cleanup'){
 $service=$q('select s.domain_uuid,s.tenant_uuid,d.domain_name,t.home_domain_uuid from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.service_name=? and t.owner_user_uuid=?',[$s['service_name'],$s['factory_admin']['user_uuid']])->fetch(PDO::FETCH_ASSOC);
 if($service){$s['owned']=$service;$save();}
 if($action==='discover'&&!$service)throw new RuntimeException('Normal HTTPS setup did not create its owned PBX.');
}
$owned=$s['owned']??null;
if(!$owned){if($action==='cleanup'){$restoreGlobals();foreach($q('select draft_uuid from v_pbx_setup_drafts where user_uuid=?',[$s['factory_admin']['user_uuid']])->fetchAll(PDO::FETCH_COLUMN) as $id)if(!in_array($id,$s['drafts_before'],true))$q('delete from v_pbx_setup_drafts where draft_uuid=?',[$id]);$factory();echo "{\"factory_empty\":true,\"owned_rows\":0}\n";exit;}throw new RuntimeException('Owned PBX is unavailable.');}
$domain=$owned['domain_uuid'];$realm=$owned['domain_name'];if(!is_uuid($domain)||!preg_match('/^pbx-[a-f0-9]{12}\./D',$realm))throw new RuntimeException('Fixture ownership mismatch.');
if($q('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn()!==$realm)throw new RuntimeException('Fixture realm mismatch.');
$admin=$s['factory_admin'];unset($_SESSION['permissions']);$permissions=(new permissions($database,$admin['domain_uuid'],$admin['user_uuid']))->get_permissions();
if(empty($permissions['pbx_tenant_manage'])||empty($permissions['pbx_service_create']))throw new RuntimeException('The genuine factory administrator is required.');
$_SESSION=['authorized'=>true,'user_uuid'=>$admin['user_uuid'],'domain_uuid'=>$domain,'domain_name'=>$realm,'user'=>['domain_uuid'=>$admin['domain_uuid']],'permissions'=>$permissions];
$pbx=new pbx_admin($db);$c=$pbx->config();
if($action==='discover'){
 $s['realm']=$realm;$s['domain']=$domain;$s['music']=pbx_paths::storage().'/openweb-music/8000/lofi-beat-loop-schmoop.wav';
 $s['users']=[];
 $auths=['8100'=>'fixture-8100','8101'=>'8102','8102'=>'fixture-8102','8103'=>'fixture-8103'];
 $db->beginTransaction();foreach($auths as $n=>$auth){
  if(!isset($c['users'][$n]))throw new RuntimeException('Normal HTTPS users missing.');$u=&$c['users'][$n];
  $u['auth_id']=$auth;$u['contact_user']=(string)$n;
  $q('update v_extensions set extension=? where domain_uuid=? and extension_uuid=?',[$auth,$domain,$u['extension_uuid']]);
  if((string)$n==='8101')$q("update v_extensions set absolute_codec_string='PCMU' where domain_uuid=? and extension_uuid=?",[$domain,$u['extension_uuid']]);
  $password=$q('select password from v_extensions where domain_uuid=? and extension_uuid=?',[$domain,$u['extension_uuid']])->fetchColumn();
  $s['users'][]=['number'=>(string)$n,'auth'=>$auth,'password'=>$password,'tone_hz'=>440+array_search($n,array_keys($auths),true)*110];
 }unset($u);
 $q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$domain]);$db->commit();$save();
 foreach($s['users'] as $u)(new cache)->delete('directory:'.$u['auth'].'@'.$realm);event_socket::api('reloadxml');echo "{\"normal_https_users_discovered\":4,\"fictional_auth_collision\":true}\n";exit;
}
if($action==='status'){
 $status=event_socket::api('sofia status profile internal');if(!preg_match('/^\s*SIP-IP\s+([0-9.]+)\s*$/m',$status,$m))throw new RuntimeException('Native profile IP unavailable.');
 $messages=$q('select m.voicemail_message_uuid,m.message_length,v.voicemail_id from v_voicemail_messages m join v_voicemails v using(voicemail_uuid,domain_uuid) where m.domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC);
 foreach($messages as &$message)$message['message_path']=pbx_paths::voicemail().'/default/'.$realm.'/'.$message['voicemail_id'].'/msg_'.$message['voicemail_message_uuid'].'.wav';unset($message);
 echo json_encode(['bind'=>$m[1],'config'=>$c,'jobs'=>$q('select job_uuid,kind,state,attempts,last_result,call_uuid from v_pbx_jobs where domain_uuid=? order by created_at',[$domain])->fetchAll(PDO::FETCH_ASSOC),'voicemail'=>$messages,'mail'=>$q('select email_queue_uuid,email_uuid,email_status,email_retry_count from v_email_queue where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC)],JSON_THROW_ON_ERROR);exit;
}
if($action==='job'){
 // Synthetic callback uses an explicit internal target. A wire caller ID is
 // never reclassified as internal. The normal C# service claims this row.
 $id=uuid();$q("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,internal_target,request_key,due_at,expires_at,max_attempts) values(?,?,'callback','8190','8100',true,?,now(),now()+interval '10 minutes',1)",[$id,$domain,'windows-native/'.$id]);echo json_encode(['job'=>$id],JSON_THROW_ON_ERROR);exit;
}
if($action==='due'){$q("update v_pbx_jobs set due_at=now() where domain_uuid=? and kind='wakeup' and state='waiting'",[$domain]);echo "{\"owned_wakeup_due\":true}\n";exit;}
if($action==='api'){
 $command=$argv[3]??'';
 $allowed=in_array($command,['status','show channels as json','sofia status profile internal','fsctl pause_check'],true);
 foreach($s['users'] as $u)foreach(['sofia_contact ','user_data '] as $prefix)if($command===$prefix.$u['auth'].'@'.$realm||$command===$prefix.$u['auth'].'@'.$realm.' param password')$allowed=true;
 if(!$allowed)throw new RuntimeException('Only owned read-only native queries are allowed.');echo event_socket::api($command);exit;
}
if($action==='mail-seed'){
 $id=uuid();$q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,email_status,email_retry_count,email_action_after) values(?,?,?,now(),?,?,?,?,'waiting',0,'')",[$id,$domain,gethostname(),'Tenant sender <tenant@example.invalid>','sink@example.invalid','Windows fictional queue '.$s['scope'],'Fictional localhost message']);$s['seed_mail']=$id;$save();echo json_encode(['id'=>$id],JSON_THROW_ON_ERROR);exit;
}
if($action==='cleanup'){
 $channels=json_decode(event_socket::api('show channels as json'),true,64,JSON_THROW_ON_ERROR);
 foreach($channels['rows']??[] as $row){$id=$row['uuid']??'';if(is_uuid($id)&&(($row['context']??'')===$realm||($row['presence_id']??'')!==''&&str_ends_with($row['presence_id'],'@'.$realm)))event_socket::api('uuid_kill '.$id.' NORMAL_CLEARING');}
 foreach($q('select call_center_agent_uuid from v_call_center_agents where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN) as $id)if(is_uuid($id)){foreach($c['queues'] as $queue)event_socket::api('callcenter_config tier del '.$queue['number'].'@'.$realm.' '.$id);event_socket::api('callcenter_config agent del '.$id);}
 foreach($c['queues'] as $queue)event_socket::api('callcenter_config queue unload '.$queue['number'].'@'.$realm);
 foreach($s['users']??[] as $u)event_socket::api('sofia profile internal flush_inbound_reg '.$u['auth'].'@'.$realm);
 $files=$q('select file_path from v_pbx_media where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN);

 foreach($files as $file)if(is_file($file)&&(pbx_paths::contains(pbx_paths::media().'/'.$domain,$file)||pbx_paths::contains(pbx_paths::voicemail(),$file))&&!is_link($file))unlink($file);
 $db->beginTransaction();
 $tables=$q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN);
 foreach([$domain,$owned['home_domain_uuid']] as $d)foreach($tables as $t)if($t!=='v_domains'&&preg_match('/^v_[a-z0-9_]+$/D',$t))$q('delete from '.$t.' where domain_uuid=?',[$d]);
 foreach($q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN) as $t)if(preg_match('/^v_[a-z0-9_]+$/D',$t))$q('delete from '.$t.' where tenant_uuid=?',[$owned['tenant_uuid']]);
 foreach([$domain,$owned['home_domain_uuid']] as $d)$q('delete from v_domains where domain_uuid=?',[$d]);
 foreach($q('select draft_uuid from v_pbx_setup_drafts where user_uuid=?',[$admin['user_uuid']])->fetchAll(PDO::FETCH_COLUMN) as $id)if(!in_array($id,$s['drafts_before'],true))$q('delete from v_pbx_setup_drafts where draft_uuid=?',[$id]);
 $restoreGlobals();
 $db->commit();settings::clear_cache();event_socket::api('reloadxml');
 $removeDirectory=static function(string $path)use(&$removeDirectory):void{
  if(!is_dir($path))return;if(is_link($path))throw new RuntimeException('Owned storage must be ordinary.');
  foreach(new DirectoryIterator($path) as $file){if($file->isDot())continue;if($file->isLink())throw new RuntimeException('Owned storage link refused.');if($file->isDir())$removeDirectory($file->getPathname());else unlink($file->getPathname());}rmdir($path);
 };
 $removeDirectory(pbx_paths::media().'/'.$domain);$removeDirectory(pbx_paths::voicemail().'/default/'.$realm);
 $factory();if($identity()!==$s['baseline'])throw new RuntimeException('Factory administrator or domain identity changed.');
 foreach($tables as $t)if(preg_match('/^v_[a-z0-9_]+$/D',$t))foreach([$domain,$owned['home_domain_uuid']] as $d)if((int)$q('select count(*) from '.$t.' where domain_uuid=?',[$d])->fetchColumn())throw new RuntimeException('Owned rows remain.');
 foreach($s['users']??[] as $u)if(!str_starts_with(trim(event_socket::api('sofia_contact '.$u['auth'].'@'.$realm)),'error/'))throw new RuntimeException('Owned native contact remains.');
 echo "{\"factory_empty\":true,\"owned_rows\":0,\"owned_contacts\":0,\"original_identity_preserved\":true}\n";exit;
}
throw new RuntimeException('Unknown native fixture operation.');
