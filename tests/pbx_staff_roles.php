<?php
/** Real PostgreSQL role/mutation boundaries, plus separate HTTP coverage in the native fixture. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/require.php';
class staff_role_scope extends pbx_staff_access {public function owner(): bool {return false;}}
class staff_role_admin extends pbx_admin {
    protected function changed(?string $trunk=null,?string $queue=null): void {}
    protected function engine(string $command): string {return '+OK';}
}
$db=$database->db;$schema='pbx_staff_'.bin2hex(random_bytes(6));$saved=$_SESSION??[];$checks=0;
$q=static function($sql,$p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
$ok=static function($value,$message)use(&$checks){if(!$value)throw new RuntimeException($message);$checks++;};
$denied=static function($call,$message)use($ok){try{$call();}catch(pbx_staff_denied){$ok(true,$message);return;}$ok(false,$message);};
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_domains','v_users','v_groups','v_user_groups','v_extensions','v_voicemails','v_voicemail_greetings','v_voicemail_messages','v_dialplans','v_dialplan_details','v_pbx_restore','v_pbx_staff_roles','v_pbx_staff_invites','v_pbx_staff_audit','v_ring_groups','v_ring_group_destinations','v_call_center_queues','v_call_center_agents','v_call_center_tiers','v_ivr_menus','v_ivr_menu_options','v_pbx_media','v_pbx_call_history','v_pbx_sip_domains']as$t)$db->exec('create table '.$t.'(like public.'.$t.' including all)');
 $a=uuid();$b=uuid();$root=uuid();foreach([$a,$b]as$d)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled)values(?,?,true)',[$d,$d.'.invalid']);
 $q("insert into v_users(user_uuid,domain_uuid,username,user_enabled)values(?,?,?,true)",[$root,$a,'systemowner115@example.invalid']);
 $q("insert into v_groups(group_uuid,group_name)values(?,'openweb_staff')",[uuid()]);
 $c=['realm'=>$a.'.invalid','timezone'=>'UTC','users'=>[],'departments'=>[],'trunks'=>[],'queues'=>[],'ring_groups'=>[],'receptionists'=>[],'scripts'=>[],'specials'=>[],'phones'=>[],'contacts'=>[],'inbound_rules'=>[],'outbound_rules'=>[]];
 foreach([$a,$b]as$d)$q("insert into v_pbx_restore(domain_uuid,source_version,config)values(?,'fictional-staff115',?::jsonb)",[$d,json_encode($c)]);
 $_SESSION=['authorized'=>true,'user_uuid'=>$root,'domain_uuid'=>$a,'domain_name'=>$c['realm']];$admin=new staff_role_admin($db);$input=['name'=>'Fictional staff','enabled'=>'1','voicemail_enabled'=>'1'];
 foreach(['1000','1001','1002','1003','1004','1005','1006']as$n)$admin->save('user','new',$input+['number'=>$n]);
 $sales=$admin->save('department','new',['name'=>'Sales','members'=>['1000','1001','1002','1003','1004','1005'],'department_options_present'=>1]);
 $support=$admin->save('department','new',['name'=>'Support','members'=>['1006'],'department_options_present'=>1]);
 $admin->save('ring_group','new',['number'=>'1100','name'=>'Sales Group','timeout'=>10,'members'=>['1000'],'department'=>$sales,'schedule_mode'=>'department']);
 $account=new pbx_staff_accounts($db);$people=[];$roles=array_keys(pbx_staff_access::roles());
 foreach($roles as$i=>$role){$n=(string)(1000+$i);$result=$account->grant(['number'=>$n,'department'=>$sales,'role'=>$role,'email'=>$role.'115@example.invalid']);$ok($result['created']&&is_string($result['invitation_url']),'New staff did not receive a private invitation');parse_str(parse_url($result['invitation_url'],PHP_URL_QUERY),$parsed);$token=$parsed['invite'];$ok($account->invitation($token)!==null,'Valid invitation refused');$account->accept($token,'Fictional-password-115!');$ok($account->invitation($token)===null,'Invitation reusable');$u=$q('select user_uuid from v_users where username=?',[$role.'115@example.invalid'])->fetchColumn();$people[$role]=['id'=>$u,'number'=>$n];}
 // A pending account can be invited again without reusing its old link.
 $pending=$account->grant(['number'=>'1006','department'=>$support,'role'=>'user','email'=>'pending115@example.invalid']);parse_str(parse_url($pending['invitation_url'],PHP_URL_QUERY),$old);$roleid=$q('select staff_role_uuid from v_pbx_staff_roles r join v_users u using(user_uuid) where username=?',['pending115@example.invalid'])->fetchColumn();$renew=$account->renew($roleid);parse_str(parse_url($renew['invitation_url'],PHP_URL_QUERY),$next);$ok($account->invitation($old['invite'])===null&&$account->invitation($next['invite'])!==null,'Renewal did not invalidate the earlier link');$account->accept($next['invite'],'Renewed-fictional-password!');try{$account->renew($roleid);$ok(false,'Accepted account was invited again');}catch(InvalidArgumentException){$ok(true,'Accepted account refuses renewal');}
 $foreign=uuid();$q("insert into v_users(user_uuid,domain_uuid,username,user_email,user_enabled)values(?,?,? ,?,true)",[$foreign,$b,'foreign115@example.invalid','foreign115@example.invalid']);
 $denied(fn()=>$account->grant(['number'=>'1000','department'=>$sales,'role'=>'user','email'=>'foreign115@example.invalid']),'A foreign PBX web account was taken over');
 $config=$admin->config();$nativePasswords=$q('select extension_uuid,password from v_extensions where domain_uuid=? order by extension_uuid',[$a])->fetchAll(PDO::FETCH_ASSOC);
 foreach($people as$role=>$person){
  $_SESSION=['authorized'=>true,'user_uuid'=>$person['id'],'domain_uuid'=>$a,'domain_name'=>$c['realm']];$scope=new staff_role_scope($db);
  $ok($scope->active()&&$scope->ownNumber()===$person['number'],'Accepted staff identity did not bind to its original extension');
  $ok(!$scope->permits('users','1006'),'A role managed the other department');
  $ok(!$scope->visible('1006'),'Hidden department leaked');
  $ok($scope->permits('personal',$person['number'])&&!$scope->permits('personal','1006'),'Personal access escaped own extension');
  $sadmin=new staff_role_admin($db,$scope);
  $before=$admin->config();$denied(fn()=>$sadmin->save('user','1006',$input),'Cross-department write succeeded');$ok($before===$admin->config(),'Rejected edit changed the PBX');
  $denied(fn()=>$sadmin->save('user','new',$input+['department'=>$support]),'Cross-department user creation succeeded');
  $denied(fn()=>$sadmin->enableCallFeatures(),'Scoped role changed global parking configuration');
  if(!in_array($role,['department_admin','manager','owner'],true))$denied(fn()=>$sadmin->save('user','1000',$input),'Read-only staff changed another user');
  $expected=['live'=>in_array($role,['receptionist','supervisor','manager','owner'],true),'users'=>in_array($role,['department_admin','manager','owner'],true),'providers'=>in_array($role,['department_admin','owner'],true),'staff'=>$role==='owner','reports'=>in_array($role,['supervisor','manager','owner'],true),'recordings'=>in_array($role,['manager','owner'],true)];
  foreach($expected as$cap=>$yes)$ok($scope->can($cap)===$yes,'Role capability matrix differs for '.$role.'/'.$cap);
  if(in_array($role,['receptionist','manager','owner'],true)){$scope->overrideHours(['department'=>$sales,'state'=>'closed','minutes'=>5]);$ok(pbx_departments::find($admin->config(),$sales)['office_override']['state']==='closed','Allowed office override failed');}
  else $denied(fn()=>$scope->overrideHours(['department'=>$sales,'state'=>'closed','minutes'=>5]),'Role overrode office hours without rights');
  $denied(fn()=>$scope->overrideHours(['department'=>$support,'state'=>'open','minutes'=>5]),'Office override crossed departments');
  $_SESSION['domain_uuid']=$b;$other=new staff_role_scope($db);$ok(!$other->active(),'Same-number role crossed PBX domains');
 }
 $_SESSION=['authorized'=>true,'user_uuid'=>$people['department_admin']['id'],'domain_uuid'=>$a,'domain_name'=>$c['realm']];$scope=new staff_role_scope($db);$sadmin=new staff_role_admin($db,$scope);
 // Shared prompts are readable; private department prompts cannot be selected by UUID.
 $sharedPrompt=uuid();$privatePrompt=uuid();$q("insert into v_pbx_media(media_uuid,domain_uuid,category,owner_number,file_path,title,source_path)values(?,?,'prompts','',?,'Shared','shared115.wav'),(?,?,'prompts','1006',?,'Private','private115.wav')",[$sharedPrompt,$a,'/fictional/shared.wav',$privatePrompt,$a,'/fictional/private.wav']);
 $ok(count($sadmin->media('prompts'))===1,'Shared/private prompt visibility differs');
 $queueInput=['name'=>'Sales Queue','number'=>'1102','timeout'=>30,'ring_timeout'=>10,'wrap_up'=>0,'members'=>['1000'],'department'=>$sales,'destination'=>'None:','intro'=>$privatePrompt];$denied(fn()=>$sadmin->save('queue','new',$queueInput),'Private prompt was selected across departments');$sadmin->save('queue','new',array_replace($queueInput,['intro'=>$sharedPrompt]));$beforePrompt=$admin->config()['queues'][0]['intro'];$sadmin->save('queue','1102',array_replace($queueInput,['intro'=>'keep-existing']));$ok($admin->config()['queues'][0]['intro']===$beforePrompt,'Saving a queue cleared its existing audio');
 $number=$sadmin->save('user','new',$input+['department'=>$sales]);$ok($scope->permits('users',$number),'Created user not bound to managed department');
 $denied(fn()=>$sadmin->save('user',$people['owner']['number'],$input),'Department administrator changed a higher staff role');
 $denied(fn()=>$sadmin->save('user',$number,$input+['department'=>$support]),'User was moved outside delegated departments');
 $_SESSION['user_uuid']=$people['user']['id'];$scope=new staff_role_scope($db);$q('update v_pbx_staff_roles set enabled=false where user_uuid=?',[$people['user']['id']]);$ok(!$scope->active(),'Revocation was cached');
 $_SESSION['user_uuid']=$people['manager']['id'];$scope=new staff_role_scope($db);$q("update v_extensions set enabled=false where extension_uuid=?",[$config['users'][$people['manager']['number']]['extension_uuid']]);$ok(!$scope->active(),'Disabled phone retained staff access');
 $q("update v_extensions set enabled=true where extension_uuid=?",[$config['users'][$people['manager']['number']]['extension_uuid']]);
 $ok($nativePasswords===$q('select extension_uuid,password from v_extensions where domain_uuid=? and extension_uuid in ('.implode(',',array_fill(0,count($nativePasswords),'?')).') order by extension_uuid',array_merge([$a],array_column($nativePasswords,'extension_uuid')))->fetchAll(PDO::FETCH_ASSOC),'Role operations changed original SIP passwords');
 echo 'PASS: '.$checks." department staff role, invite, revocation, mutation and isolation controls\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');$_SESSION=$saved;}
