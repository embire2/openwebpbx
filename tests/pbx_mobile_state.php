<?php
/** CLI-only: isolated schema, real transactions, no carrier calls. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
class state_fixture extends pbx_mobile_state {public array $commands=[];protected function engine(string $command): string {$this->commands[]=$command;return '+OK';}}
class push_fixture extends pbx_mobile_push {public bool $active=true;public string $domain='',$extension='';protected function engine(string $command): string {if(str_ends_with($command,' domain_uuid'))return $this->domain;if(str_ends_with($command,' openweb_mobile_wake_targets'))return $this->extension;return str_starts_with($command,'uuid_exists ')?($this->active?'true':'false'):'_undef_';}}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='mobile_state_'.bin2hex(random_bytes(6));$checks=0;
$q=function($sql,$p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
if(($argv[1]??'')==='--queue-child'){
    $schema=$argv[2]??'';if(!preg_match('/^mobile_state_[a-f0-9]{12}$/D',$schema))exit(2);
    $db->exec('set search_path to '.$schema.',public');$q('select set_config(\'application_name\',?,false)',[$schema.'-queue-child']);
    $account=json_decode($argv[3],true,512,JSON_THROW_ON_ERROR);echo "READY\n";flush();
    (new state_fixture($db))->queue($account,['number'=>'8000','joined'=>false]);echo "DONE\n";exit;
}
$check=function($v,$label)use(&$checks){if(!$v)throw new RuntimeException($label);$checks++;};
$reject=function($f,$label)use($check){try{$f();}catch(InvalidArgumentException|OutOfBoundsException){$check(true,$label);return;}$check(false,$label);};
try{
$db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
foreach(['v_domains','v_users','v_extensions','v_pbx_restore','v_pbx_services','v_pbx_tenants','v_pbx_jobs'] as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
$db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_mobile/resources/install.sql'));
$accounts=[];$profiles=['Available'=>['queue_status'=>'1','available'=>[],'away'=>[],'timeout'=>20],'Away'=>['queue_status'=>'0','available'=>[],'away'=>['Internal'=>[]],'timeout'=>20],'Out of office'=>['queue_status'=>'0','available'=>[],'away'=>['Internal'=>[]],'timeout'=>20]];
for($i=0;$i<2;$i++){
$d=uuid();$e=uuid();$agent=uuid();$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$d,$d.'.invalid']);$q("insert into v_extensions(extension_uuid,domain_uuid,extension,enabled) values(?,?,'1000',true)",[$e,$d]);
$c=['realm'=>$d.'.invalid','users'=>['1000'=>['number'=>'1000','extension_uuid'=>$e,'enabled'=>true,'voicemail_enabled'=>true,'voicemail_uuid'=>uuid(),'profile'=>'Available','profiles'=>$profiles,'queue_status'=>'LoggedIn'],'1001'=>['number'=>'1001','extension_uuid'=>uuid(),'enabled'=>true,'profile'=>'Available','profiles'=>$profiles]],'queues'=>[['number'=>'8000','name'=>'Support','members'=>[['number'=>'1000','status'=>'LoggedIn','agent_uuid'=>$agent],['number'=>'1001','status'=>'LoggedIn','agent_uuid'=>uuid()]]],['number'=>'8001','name'=>'Private','members'=>[['number'=>'1001','status'=>'LoggedIn']]]]];
$q("insert into v_pbx_restore(domain_uuid,source_version,config) values(?,'fixture',?::jsonb)",[$d,json_encode($c)]);$accounts[]=['domain_uuid'=>$d,'extension_uuid'=>$e,'number'=>'1000','device_uuid'=>uuid()];
}
$state=new state_fixture($db);$a=$accounts[0];$read=$state->read($a);$check(count($read['queues'])===1&&$read['queues'][0]['receiving'],'Only assigned queues visible');
$before=$q('select config from v_pbx_restore where domain_uuid=?',[$accounts[1]['domain_uuid']])->fetchColumn();
$result=$state->status($a,['status'=>'Do Not Disturb','minutes'=>15]);$check($result['status']==='Do Not Disturb'&&!$result['queues'][0]['receiving'],'DND blocks queues');
$c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$a['domain_uuid']])->fetchColumn(),true);$check($c['users']['1000']['profiles']['Do Not Disturb']['disable_ring_groups']&&$c['users']['1000']['profiles']['Do Not Disturb']['away']['Internal']['all']['number']==='1000','DND routes to own mailbox and blocks groups');
$check($c['users']['1001']['profile']==='Available','Colleague status preserved');
$result=$state->status($a,['status'=>'Away','minutes'=>30]);$check($q('select previous_profile from v_pbx_mobile_presence')->fetchColumn()==='Available','Temporary changes preserve original return status');
$c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$a['domain_uuid']])->fetchColumn(),true);$c['users']['1000']['mobile_temporary']['expires']=time()-1;$check(pbx_mobile_state::profile($c['users']['1000'])==='Available','Expiry effective without worker');
$result=$state->status($a,['status'=>'Available','minutes'=>0]);$check($result['temporary_until']===null&&(int)$q('select count(*) from v_pbx_mobile_presence')->fetchColumn()===0,'Permanent status cancels expiry');
$result=$state->queue($a,['number'=>'8000','joined'=>false]);$check(!$result['queues'][0]['joined']&&!$result['queues'][0]['receiving'],'Leave queue persists');
$result=$state->queue($a,['number'=>'8000','joined'=>true]);$check($result['queues'][0]['joined']&&$result['queues'][0]['receiving'],'Join queue persists');
$check(end($state->commands)==='lua app/pbx_setup/mobile_state.lua '.$a['domain_uuid'].' 1000','Agent synchronization reads latest committed settings without unloading queue');
$reject(fn()=>$state->queue($a,['number'=>'8001','joined'=>true]),'Unassigned queue denied');
$reject(fn()=>$state->status($a,['status'=>'Administrator','minutes'=>0]),'Unknown profile denied');
$reject(fn()=>$state->status($a,['status'=>'Available','minutes'=>-1]),'Invalid expiry denied');
$reject(fn()=>$state->status(array_merge($a,['extension_uuid'=>$accounts[1]['extension_uuid']]),['status'=>'Away']),'Foreign extension UUID denied');
$check($before===$q('select config from v_pbx_restore where domain_uuid=?',[$accounts[1]['domain_uuid']])->fetchColumn(),'Other tenant with matching number preserved');
$q('update v_extensions set enabled=false where extension_uuid=?',[$a['extension_uuid']]);$reject(fn()=>$state->read($a),'Disabled native extension denied');$q('update v_extensions set enabled=true where extension_uuid=?',[$a['extension_uuid']]);
$q('update v_domains set domain_enabled=false where domain_uuid=?',[$a['domain_uuid']]);$reject(fn()=>$state->read($a),'Disabled PBX denied');$q('update v_domains set domain_enabled=true where domain_uuid=?',[$a['domain_uuid']]);
$owner=uuid();$tenant=uuid();$q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled) values(?,?,'fixture-owner','fixture@example.invalid','unusable-fixture-password',true)",[$owner,$a['domain_uuid']]);
$q("insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,'Fixture','fixture',?,?,'fixture@example.invalid',false)",[$tenant,$a['domain_uuid'],$owner]);
$q("insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,template_name,template_version,service_name,request_uuid,created_by) values(?,?,?,'Fixture',1,'Fixture',?,?)",[uuid(),$tenant,$a['domain_uuid'],uuid(),$owner]);
$reject(fn()=>$state->status($a,['status'=>'Away','minutes'=>0]),'Suspended tenant cannot change presence');$q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$tenant]);
$c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$a['domain_uuid']])->fetchColumn(),true);$c['users']['1000']['voicemail_enabled']=false;unset($c['users']['1000']['profiles']['Do Not Disturb']);$q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c),$a['domain_uuid']]);
$state->status($a,['status'=>'Do Not Disturb','minutes'=>0]);$c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$a['domain_uuid']])->fetchColumn(),true);
$check($c['users']['1000']['profiles']['Do Not Disturb']['away']['Internal']['all']['type']==='EndCall','DND without mailbox ends the call rather than promising voicemail');
$state->status($a,['status'=>'Available','minutes'=>0]);
$q("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,target_number,request_key,state,agent_number) values(?,?,'callback','1001','fixture','calling','1000')",[uuid(),$a['domain_uuid']]);
$read=$state->read($a);$check(!$read['queues'][0]['receiving']&&$read['queues'][0]['receiving_reason']==='A callback is using your phone','Reserved callbacks pause queue eligibility');$q('delete from v_pbx_jobs');
// Schedule cases use a fixed Monday in the department timezone, including boundary times.
$u=$c['users']['1000'];$u['profile']='Available';$u['auto_status']='1';$clockConfig=['timezone'=>'UTC','departments'=>[['timezone'=>'Africa/Johannesburg','members'=>[['number'=>'1000','primary'=>true]],'hours'=>['type'=>'SpecifiedHours','periods'=>[['day'=>1,'start'=>'08:00','end'=>'17:00']]],'breaks'=>['type'=>'SpecifiedHours','periods'=>[['day'=>1,'start'=>'12:00','end'=>'13:00']]],'holidays'=>[]]]];
$at=fn($t)=>strtotime('2026-10-12 '.$t.' UTC');
$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('06:00'))==='Available','Office start includes boundary in correct timezone');
$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('10:30'))==='Away','Lunch break reports Away');
$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('15:00'))==='Out of office','Office end excludes boundary');
$clockConfig['departments'][0]['holidays']=[['date'=>'2026-10-12']];$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('07:00'))==='Out of office','Holiday reports Out of office');$clockConfig['departments'][0]['holidays']=[];
$u['profile']='Do Not Disturb';$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('16:00'))==='Do Not Disturb','Permanent DND overrides office schedules');
$u['profile']='Available';$u['mobile_temporary']=['target'=>'Available','previous'=>'Available','expires'=>$at('17:00')];$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('16:00'))==='Available','Temporary availability overrides outside-office schedule');
$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('18:00'))==='Out of office','Expired availability reapplies office schedule');
$u['profile']='Do Not Disturb';$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('16:00'))==='Do Not Disturb','Admin override takes precedence over stale temporary marker');
$u['profile']='Available';unset($u['mobile_temporary']);$clockConfig['departments'][0]['office_override']=['state'=>'open','expires'=>$at('17:00')];
$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('16:00'))==='Available','Open-office override matches shared routing policy');
$clockConfig['departments'][0]['office_override']=['state'=>'closed','expires'=>$at('09:00')];$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('07:00'))==='Out of office','Closed-office override matches shared routing policy');
$check(pbx_mobile_state::profile($u,$clockConfig,'1000',$at('09:00'))==='Available','Expired office override restores normal schedule');
// An independently connected PHP request must wait for the same configuration row
// and preserve an Admin edit made while it waits, rather than lose an update.
$db->beginTransaction();$locked=json_decode($q('select config from v_pbx_restore where domain_uuid=? for update',[$a['domain_uuid']])->fetchColumn(),true);
$process=proc_open([PHP_BINARY,__FILE__,'--queue-child',$schema,json_encode($a)], [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
if(!is_resource($process))throw new RuntimeException('Could not run concurrent request');fclose($pipes[0]);
$check(trim((string)fgets($pipes[1]))==='READY','Independent request ready');$waiting=false;$deadline=microtime(true)+3;
do{$waiting=(bool)$q("select 1 from pg_stat_activity where application_name=? and wait_event_type='Lock'",[$schema.'-queue-child'])->fetchColumn();if(!$waiting)usleep(10000);}while(!$waiting&&microtime(true)<$deadline);
$check($waiting&&proc_get_status($process)['running'],'Independent request waits for actual PostgreSQL row lock');
$locked['users']['1000']['profile']='Away';$q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($locked),$a['domain_uuid']]);$db->commit();
$output=stream_get_contents($pipes[1]);$errors=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$check(proc_close($process)===0&&trim($output)==='DONE'&&$errors==='','Independent request completes after commit');
$read=$state->read($a);$check($read['status']==='Away'&&!$read['queues'][0]['joined'],'Concurrent queue change preserves committed Admin status');$state->status($a,['status'=>'Available','minutes'=>0]);
$c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$a['domain_uuid']])->fetchColumn(),true);$c['users']['1000']['queue_status']='LoggedOut';$c['queues'][0]['members'][0]['status']='LoggedIn';$c['queues'][]=['number'=>'8003','name'=>'Second assigned queue','members'=>[['number'=>'1000','status'=>'LoggedIn','agent_uuid'=>uuid()]]];
$q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c),$a['domain_uuid']]);$read=$state->read($a);$check(!$read['queues'][0]['joined']&&$read['queues'][0]['receiving_reason']==='Signed out of queues','Global sign-out shows unchecked effective membership');
$read=$state->queue($a,['number'=>'8000','joined'=>true]);$check($read['queues'][0]['joined']&&$read['queues'][0]['receiving']&&!$read['queues'][1]['joined'],'Explicit join signs back in to selected queue only');
$c=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$a['domain_uuid']])->fetchColumn(),true);$check($c['queues'][0]['members'][1]['status']==='LoggedIn','Global sign-in preserves colleague membership');
$c['queues'][0]['members'][0]['supervisor_break']=true;$q('update v_pbx_restore set config=?::jsonb where domain_uuid=?',[json_encode($c),$a['domain_uuid']]);$read=$state->read($a);$check($read['queues'][0]['joined']&&!$read['queues'][0]['receiving']&&$read['queues'][0]['receiving_reason']==='Paused by supervisor','Supervisor break pauses a joined queue with an explanation');
$state->queue($a,['number'=>'8000','joined'=>false]);$read=$state->queue($a,['number'=>'8000','joined'=>true]);$check(!$read['queues'][0]['receiving']&&$read['queues'][0]['receiving_reason']==='Paused by supervisor','Agent queue toggles cannot clear supervisor break');
$push=new push_fixture($db);$push->domain=$a['domain_uuid'];$push->extension=$a['extension_uuid'];$check(!$push->client()['enabled'],'Unconfigured push clearly disabled');
$q("insert into v_pbx_mobile_devices(device_uuid,domain_uuid,extension_uuid,device_name,platform,token_hash,sip_username,sip_a1_hash,expires_at) values(?,?,?,'Fixture','android',?,?,?,now()+interval '1 day')",[$a['device_uuid'],$a['domain_uuid'],$a['extension_uuid'],bin2hex(random_bytes(32)),'owm-'.bin2hex(random_bytes(16)),bin2hex(random_bytes(16))]);
$reject(fn()=>$push->register($a,['token'=>str_repeat('a',30),'project_id'=>'fixture-project']),'Push registration disabled until configured');
$q("insert into v_pbx_mobile_push_config(singleton,enabled,project_id,client_config) values(true,true,'fixture-project','{}')");
$reject(fn()=>$push->register($a,['token'=>str_repeat('a',30),'project_id'=>'foreign-project']),'Foreign Firebase project denied');
$push->register($a,['token'=>str_repeat('a',30),'project_id'=>'fixture-project']);$check($q('select push_token from v_pbx_mobile_devices')->fetchColumn()===str_repeat('a',30),'Authenticated device registered');
$request=uuid();$q("insert into v_pbx_mobile_push_calls(request_uuid,call_uuid,device_uuid,domain_uuid,extension_uuid,expires_at) values(?,?,?,?,?,now()+interval '30 seconds')",[$request,uuid(),$a['device_uuid'],$a['domain_uuid'],$a['extension_uuid']]);
$check($push->call($a,$request)['ringing'],'Live owned request can wake phone');
$reject(fn()=>$push->call($accounts[1],$request),'Foreign wake-up request denied');
$push->active=false;$check(!$push->call($a,$request)['ringing'],'Ended call never rings');$push->active=true;$push->dismiss($a,$request);$check(!$push->call($a,$request)['ringing'],'Decline dismisses only owned request');
echo 'PASS: '.$checks." status, queue, tenant-isolation and push-lifecycle checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
