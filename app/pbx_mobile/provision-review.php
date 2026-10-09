<?php
/** Operator CLI: create/resume one isolated, reusable app-review tenant. Never prints secrets. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
umask(0077);
if(function_exists('posix_geteuid')&&posix_geteuid()!==0)throw new RuntimeException('Run as the instance administrator.');
require dirname(__DIR__,2).'/resources/require.php';
$output=$argv[1]??'';$dir=realpath(dirname($output));
if(!$dir||!str_starts_with($output,'/')||is_link($output)||(fileperms($dir)&0077)!==0||str_starts_with($dir,PROJECT_ROOT)||str_starts_with($dir,'/var/www/'))throw new RuntimeException('Choose a credential file in an existing private directory outside the application and web root.');
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$q=static function(string $sql,array $p=[])use($db){$s=$db->prepare($sql);foreach($p as $k=>$v)$s->bindValue(is_int($k)?$k+1:':'.$k,$v,is_bool($v)?PDO::PARAM_BOOL:($v===null?PDO::PARAM_NULL:PDO::PARAM_STR));$s->execute();return $s;};
$write=static function(array $state)use($output){$temp=$output.'.tmp';if(is_link($temp))throw new RuntimeException('Unsafe state file.');if(file_put_contents($temp,json_encode($state,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR),LOCK_EX)===false||!chmod($temp,0600)||!rename($temp,$output))throw new RuntimeException('Could not save private review state.');};
$q("select pg_advisory_lock(hashtext('openweb-mobile-review-provision'))");
try{
 $db->exec(file_get_contents(__DIR__.'/resources/install.sql'));
 if(file_exists($output)){
  if((fileperms($output)&0077)!==0)throw new RuntimeException('Review state must have mode 600.');
  $state=json_decode(file_get_contents($output),true,64,JSON_THROW_ON_ERROR);
  if(($state['purpose']??'')!=='openweb-google-play-review-v1')throw new RuntimeException('Unrecognized private state.');
 }else{
  if($q("select 1 from v_pbx_tenants where slug='google-play-review'")->fetchColumn())throw new RuntimeException('Review tenant already exists. Use its original private state file.');
  $state=['purpose'=>'openweb-google-play-review-v1','stage'=>'prepared','domain'=>uuid(),'home'=>uuid(),'tenant'=>uuid(),'user'=>uuid(),'group'=>uuid(),'service'=>uuid(),'echo_dialplan'=>uuid(),'sample_message'=>uuid(),'realm'=>'google-play-review.'.pbx_paths::host(),'username'=>'google-play-review@'.pbx_paths::host(),'password'=>bin2hex(random_bytes(18)),'portal'=>pbx_paths::url().'/app/pbx_mobile/review.php','extension'=>'7001','echo'=>'7000','voicemail'=>'7002'];$write($state);
 }
 foreach(['domain','home','tenant','user','group','service','echo_dialplan','sample_message'] as $key)if(!is_uuid($state[$key]??''))throw new RuntimeException('Invalid private review state.');
 if(($state['realm']??'')!=='google-play-review.'.pbx_paths::host()||!filter_var($state['username']??'',FILTER_VALIDATE_EMAIL)||strlen($state['password']??'')<32)throw new RuntimeException('Review instance or credentials do not match.');
 $existing=$q('select domain_name from v_domains where domain_uuid=?',[$state['domain']])->fetchColumn();
 if($existing&&$existing!==$state['realm'])throw new RuntimeException('Review ownership mismatch.');
 $_SESSION=['authorized'=>true,'user_uuid'=>$state['user'],'domain_uuid'=>$state['domain'],'domain_name'=>$state['realm'],'user'=>['domain_uuid'=>$state['domain']]];
 if(!$existing){
  $db->beginTransaction();
  try{
   $q('insert into v_domains(domain_uuid,domain_name,domain_description,domain_enabled) values(?,?,?,true)',[$state['home'],'workspace.'.$state['realm'],'App review workspace']);
   $q('insert into v_domains(domain_uuid,domain_name,domain_description,domain_enabled) values(?,?,?,true)',[$state['domain'],$state['realm'],'App review demo only']);
   $q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled,user_type) values(?,?,?,?,?,false,'default')",[$state['user'],$state['domain'],$state['username'],$state['username'],password_hash($state['password'],PASSWORD_DEFAULT)]);
   $q("insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,invite_email,service_limit) values(?,'Google Play review','google-play-review',?,?,1)",[$state['tenant'],$state['home'],$state['username']]);
   $q("insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,template_name,template_version,service_name,request_uuid,created_by) values(?,?,?,'Isolated app review',1,'Review demo',?,?)",[$state['service'],$state['tenant'],$state['domain'],uuid(),$state['user']]);
   $q("insert into v_groups(group_uuid,domain_uuid,group_name,group_level,group_description,group_protected) values(?,?,'app_reviewer',5,'Connect assigned demo phone only',true)",[$state['group'],$state['domain']]);
   $q("insert into v_permissions(permission_uuid,permission_name,application_name,application_uuid,permission_description) select ?,'pbx_mobile_review','Android App','e7084e22-931b-46cd-9e82-ec3df59bb1a7','Connect assigned demo phone only' where not exists(select 1 from v_permissions where permission_name='pbx_mobile_review')",[uuid()]);
   $q("insert into v_group_permissions(group_permission_uuid,group_uuid,group_name,permission_name,permission_assigned) values(?,?,'app_reviewer','pbx_mobile_review',true)",[uuid(),$state['group']]);
   $q("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(?,?,?,?,'app_reviewer')",[uuid(),$state['domain'],$state['user'],$state['group']]);
   $q("insert into v_user_settings(user_setting_uuid,domain_uuid,user_uuid,user_setting_category,user_setting_subcategory,user_setting_name,user_setting_value,user_setting_enabled) values(?,?,?,'login','destination','text','/app/pbx_mobile/review.php',true)",[uuid(),$state['domain'],$state['user']]);
   (new pbx_admin($db))->initialize($state['realm'],'UTC');$db->commit();
  }catch(Throwable $ex){if($db->inTransaction())$db->rollBack();throw $ex;}
 }
 $owner=$q('select user_enabled,password from v_users where user_uuid=? and domain_uuid=? and username=?',[$state['user'],$state['domain'],$state['username']])->fetch(PDO::FETCH_ASSOC);
 if(!$owner||!password_verify($state['password'],$owner['password'])||!$q('select 1 from v_pbx_services where service_uuid=? and tenant_uuid=? and domain_uuid=? and created_by=?',[$state['service'],$state['tenant'],$state['domain'],$state['user']])->fetchColumn())throw new RuntimeException('Review ownership or credentials do not match.');
 $admin=new pbx_admin($db);$config=$admin->config();
 if(!empty($config['trunks'])||!empty($config['outbound_rules'])||!empty($config['inbound_rules'])||$q('select 1 from v_gateways where domain_uuid=?',[$state['domain']])->fetchColumn())throw new RuntimeException('The review service must have no providers or outside calling rules.');
 // Stop every other dialled number before shared default dialplans can run.
 if(!isset($state['block_dialplan'])){$state['block_dialplan']=uuid();$write($state);}
 if(!is_uuid($state['block_dialplan']))throw new RuntimeException('Invalid demo routing identifier.');
 $blockXml='<extension name="OpenWeb review internal only" uuid="'.$state['block_dialplan'].'" continue="false"><condition field="destination_number" expression="^.*$"><action application="hangup" data="CALL_REJECTED"/></condition></extension>';
 $blockAdded=$q("insert into v_dialplans(dialplan_uuid,domain_uuid,dialplan_name,dialplan_context,dialplan_order,dialplan_continue,dialplan_enabled,dialplan_xml,dialplan_description) values(?,?,'Review internal calls only',?,90,false,true,?,'No outside calls or shared feature codes') on conflict(dialplan_uuid) do nothing",[$state['block_dialplan'],$state['domain'],$state['realm'],$blockXml])->rowCount();
 if($blockAdded){(new cache)->delete('dialplan:'.$state['realm']);event_socket::api('reloadxml');}
 $xml='<extension name="OpenWeb review audio" uuid="'.$state['echo_dialplan'].'" continue="false"><condition field="destination_number" expression="^7000$"><action application="set" data="domain_uuid='.$state['domain'].'"/><action application="lua" data="app/pbx_setup/review_echo.lua"/></condition></extension>';
 $oldEcho=$q('select dialplan_xml from v_dialplans where dialplan_uuid=? and domain_uuid=?',[$state['echo_dialplan'],$state['domain']])->fetchColumn();
 if($oldEcho===str_replace('app/pbx_setup/review_echo.lua','app/pbx_mobile/review_echo.lua',$xml)){
  $q('update v_dialplans set dialplan_xml=? where dialplan_uuid=? and domain_uuid=?',[$xml,$state['echo_dialplan'],$state['domain']]);(new cache)->delete('dialplan:'.$state['realm']);event_socket::api('reloadxml');
 }
 if($state['stage']==='complete'){
  if(!$q('select 1 from v_pbx_mobile_reviewers where user_uuid=? and domain_uuid=? and extension_uuid=? and enabled',[$state['user'],$state['domain'],$state['extension_uuid']])->fetchColumn())throw new RuntimeException('Review assignment changed; inspect it before continuing.');
  echo "Review access already exists; original credentials and demo data preserved.\n";return;
 }
 foreach(['7001'=>'Review Phone','7002'=>'Leave a Message'] as $number=>$name){if(isset($config['users'][$number]))continue;$admin->save('user','new',['number'=>(string)$number,'name'=>$name,'profile'=>'Available','timeout'=>'20','enabled'=>'1','voicemail_enabled'=>'1','voicemail_email'=>'None']);$config=$admin->config();}
 // The demo message line forwards only to the assigned demo mailbox.
 $admin->save('user','7002',['name'=>'Leave a Message','profile'=>'Away','timeout'=>'20','enabled'=>'1','voicemail_enabled'=>'1','voicemail_email'=>'None','away'=>'VoiceMail:7001']);
 $config=$admin->config();$state['extension_uuid']=$config['users']['7001']['extension_uuid'];$state['voicemail_uuid']=$config['users']['7001']['voicemail_uuid'];
 // 7001 and 7002 already appear as enabled users in the Android directory.
 $config['contacts']=[['first_name'=>'Audio Test','last_name'=>'','company'=>'OpenWeb PBX demo','phone'=>'7000','owner'=>'']];
 $db->beginTransaction();try{
  $q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($config,JSON_THROW_ON_ERROR),$state['domain']]);
  $q("insert into v_dialplans(dialplan_uuid,domain_uuid,dialplan_name,dialplan_number,dialplan_context,dialplan_order,dialplan_continue,dialplan_enabled,dialplan_xml,dialplan_description) values(?,?,'Review audio test','7000',?,70,false,true,?,'Only assigned app-review phones') on conflict(dialplan_uuid) do nothing",[$state['echo_dialplan'],$state['domain'],$state['realm'],$xml]);
  $pcm='';for($i=0;$i<16000;$i++)$pcm.=pack('v',(int)(sin(2*M_PI*440*$i/8000)*5000)&0xffff);
  $wave='RIFF'.pack('V',36+strlen($pcm)).'WAVEfmt '.pack('VvvVVvv',16,1,1,8000,16000,2,16).'data'.pack('V',strlen($pcm)).$pcm;
  $q("insert into v_voicemail_messages(voicemail_message_uuid,domain_uuid,voicemail_uuid,created_epoch,message_length,message_status,message_base64,caller_id_name,caller_id_number) values(?,?,?,extract(epoch from now()),2,'new',?,'Sample audio test','7000') on conflict(voicemail_message_uuid) do nothing",[$state['sample_message'],$state['domain'],$state['voicemail_uuid'],base64_encode($wave)]);
  $q("insert into v_pbx_mobile_reviewers(user_uuid,domain_uuid,extension_uuid,echo_number,voicemail_number) values(?,?,?,'7000','7002') on conflict(user_uuid) do nothing",[$state['user'],$state['domain'],$state['extension_uuid']]);
  $q('update v_users set user_enabled=true where user_uuid=? and domain_uuid=?',[$state['user'],$state['domain']]);$db->commit();
 }catch(Throwable $ex){if($db->inTransaction())$db->rollBack();throw $ex;}
 $state['stage']='complete';$write($state);
 $media=pbx_paths::media().'/'.$state['domain'];if(PHP_OS_FAMILY==='Linux'){chown($media,'www-data');chgrp($media,'www-data');}
 settings::clear_cache();(new cache)->delete('dialplan:'.$state['realm']);event_socket::api('reloadxml');
 echo "Review tenant, two demo extensions, private login and reusable QR portal are ready. No outside provider or calling route was created.\n";
}finally{$q("select pg_advisory_unlock(hashtext('openweb-mobile-review-provision'))");}
