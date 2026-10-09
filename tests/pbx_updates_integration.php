<?php
/** CLI-only real PostgreSQL authorization/queue checks in a disposable schema. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
class update_fixture extends pbx_updates {
    public bool $manage = true;
    public bool $instance = true;
    protected function allowed(string $name): bool { return $name === 'pbx_update_manage' ? $this->manage : $this->instance; }
}
$db=$database->db; $db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_updates_test_'.bin2hex(random_bytes(6)); $checks=0;
$q=function($sql,$params=[]) use($db) { $s=$db->prepare($sql);$s->execute($params);return $s; };
$check=function($ok,$message) use(&$checks) { if(!$ok)throw new RuntimeException($message);$checks++; };
$deny=function(callable $action,$message) use($check) { try{$action();}catch(DomainException|InvalidArgumentException|OverflowException){$check(true,$message);return;}$check(false,$message); };
try {
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_pbx_tenants','v_pbx_services','v_permissions','v_groups','v_group_permissions'] as $table) $db->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_permissions','v_groups','v_group_permissions'] as $table) $db->exec('insert into '.$table.' select * from public.'.$table);
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_updates/resources/install.sql'));
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_updates/resources/install.sql'));
    $check((int)$q('select count(*) from v_pbx_update_policies')->fetchColumn()===1,'Migration is repeatable');
    $admin=uuid();$users=[uuid(),uuid()];$tenants=[uuid(),uuid()];$domains=[uuid(),uuid()];$outsider=uuid();
    foreach($domains as $i=>$domain){
        $q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$domain,$domain.'.invalid']);
        $q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,?,true)',[$users[$i],$domain,'fixture-'.$i]);
        $q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,?,?,?,?,?,true)',[$tenants[$i],'Tenant '.$i,'updates-'.$i,$domain,$users[$i],'fixture-'.$i.'@example.invalid']);
        $q("insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,template_name,template_version,service_name,request_uuid,created_by) values(?,?,?,'Test',1,'Test',?,?)",[uuid(),$tenants[$i],$domain,uuid(),$users[$i]]);
    }
    foreach([$admin,$outsider] as $id)$q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,?,true)',[$id,$domains[0],$id]);
    $_SESSION=['authorized'=>true,'user_uuid'=>$admin];$updates=new update_fixture($db);
    $check($updates->canView()&&count($updates->tenants())===2,'Instance admin sees tenants');
    $check($updates->instancePolicy()['mode']==='notify','Server defaults to optional');
    $updates->saveInstance(['mode'=>'automatic','maintenance_hour'=>'23','maintenance_duration'=>'3']);
    $check($updates->instancePolicy()['mode']==='automatic'&&(int)$updates->instancePolicy()['maintenance_hour']===23,'Automatic server policy saved');
    $deny(fn()=>$updates->saveInstance(['mode'=>'required','maintenance_hour'=>'2','maintenance_duration'=>'2']),'Mobile mode not allowed on shared server');
    foreach([['maintenance_hour'=>'24','maintenance_duration'=>'2'],['maintenance_hour'=>'0','maintenance_duration'=>'0'],['maintenance_hour'=>[],'maintenance_duration'=>'2']] as $bad)$deny(fn()=>$updates->saveInstance($bad+['mode'=>'automatic']),'Invalid maintenance window rejected');
    $updates->saveTenant($tenants[0],['mode'=>'required']);$updates->saveTenant($tenants[1],['mode'=>'download']);
    $policy=$updates->phonePolicy(['domain_uuid'=>$domains[0]]);
    $check($policy['mode']==='required'&&$policy['feed_url']===pbx_updates::FEED_URL&&count($policy)===5,'Phone receives only its own policy and fixed public feed');
    $check($updates->phonePolicy(['domain_uuid'=>$domains[1]])['mode']==='download','Second tenant policy stays independent');
    $check($updates->phonePolicy(['domain_uuid'=>uuid()])['mode']==='notify','Unassigned standalone PBX defaults optional');
    $first=$updates->request('check');$check($updates->request('check')===$first,'Duplicate requests for the same action are coalesced');
    $deny(fn()=>$updates->request('install'),'A different action is explicitly refused while a request is pending');
    $q("update v_pbx_update_commands set status='completed',finished_at=now() where command_uuid=?",[$first]);
    $second=$updates->request('install');$check($second!==$first,'New request after completion has its own identifier');
    $deny(fn()=>$updates->request('sh -c unsafe'),'Arbitrary action rejected');
    $q("update v_pbx_update_status set status_json=?::jsonb,updated_at=now() where singleton=1",[json_encode(['state'=>'downloaded','message'=>'Ready','progress_bytes'=>9,'total_bytes'=>10,'private_path'=>'hidden','token'=>'hidden'])]);
    $status=$updates->status();$check($status['service_online']&&$status['progress_bytes']===9&&!isset($status['token'],$status['private_path']),'Status allowlist excludes private fields');
    $q("update v_pbx_update_status set updated_at=now()-interval '4 minutes'");$check(!$updates->status()['service_online'],'Stale updater heartbeat detected');
    $updates->instance=false;$_SESSION['user_uuid']=$users[0];
    $check($updates->canView()&&count($updates->tenants())===1,'Tenant owner sees one tenant');
    $updates->saveTenant($tenants[0],['mode'=>'notify']);$check($updates->tenantPolicy($tenants[0])['mode']==='notify','Tenant owner may change own policy');
    $deny(fn()=>$updates->tenantPolicy($tenants[1]),'Foreign tenant read denied');
    $deny(fn()=>$updates->saveTenant($tenants[1],['mode'=>'required']),'Foreign tenant mutation denied');
    $deny(fn()=>$updates->saveTenant($tenants[0],['mode'=>'automatic']),'Server policy not accepted for phones');
    $deny(fn()=>$updates->instancePolicy(),'Tenant cannot read instance policy');
    $deny(fn()=>$updates->saveInstance(['mode'=>'automatic','maintenance_hour'=>'2','maintenance_duration'=>'2']),'Tenant cannot mutate instance policy');
    $deny(fn()=>$updates->request('install'),'Tenant cannot restart shared instance');
    $deny(fn()=>$updates->status(),'Tenant cannot read other administrators requests');
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$tenants[0]]);
    $check(!$updates->canView(),'Suspended tenant cannot view settings');
    $deny(fn()=>$updates->saveTenant($tenants[0],['mode'=>'required']),'Suspended tenant cannot save');
    try{$updates->phonePolicy(['domain_uuid'=>$domains[0]]);$check(false,'Suspended phone denied');}catch(UnexpectedValueException){$check(true,'Suspended phone denied');}
    $q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$tenants[0]]);
    $_SESSION['user_uuid']=$outsider;$check(!$updates->canView(),'Other tenant member cannot manage tenant owner policy');
    $_SESSION['user_uuid']=$users[0];$updates->manage=false;$check(!$updates->canView(),'Missing permission denied');
    $updates->manage=true;$q("update v_users set user_enabled='false' where user_uuid=?",[$users[0]]);$check(!$updates->canView(),'Disabled administrator denied');
    $_SESSION['user_uuid']=$admin;$updates->instance=true;$_SESSION['authorized']=false;$check(!$updates->canView(),'Unauthenticated session denied');$_SESSION['authorized']=true;
    $q("update v_pbx_update_commands set status='completed'");
    for($i=0;$i<18;$i++)$q("insert into v_pbx_update_commands(command_uuid,action,status) values(?,'check','completed')",[uuid()]);
    $deny(fn()=>$updates->request('check'),'Request rate limited');
    $check((int)$q("select count(*) from v_group_permissions where group_name='tenant_admin' and permission_name='pbx_update_instance'")->fetchColumn()===0,'Migration never grants tenant global update permission');
    echo 'PASS: '.$checks." PostgreSQL update policy, ownership, queue and status checks\n";
} finally { if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade'); }
