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
    $check(pbx_updates::serverFeedUrl('Windows')===pbx_updates::WINDOWS_FEED_URL,'Windows server selects the fixed independent feed');
    $check(pbx_updates::FEED_URL==='https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json','Android retains its original fixed feed');
    $check(pbx_updates::serverFeedUrl('Linux')===pbx_updates::DEBIAN_FEED_URL&&pbx_updates::DEBIAN_FEED_URL!==pbx_updates::FEED_URL,'Debian server selects its fixed independent feed');
    $check($updates->instancePolicy()['feed_url']===pbx_updates::serverFeedUrl(),'Instance policy exposes only the built-in server feed');
    $updates->saveInstance(['mode'=>'automatic','maintenance_hour'=>'23','maintenance_duration'=>'3','feed_url'=>'https://example.invalid/feed','debian_feed_url'=>pbx_updates::FEED_URL]);
    $check($updates->instancePolicy()['mode']==='automatic'&&(int)$updates->instancePolicy()['maintenance_hour']===23,'Automatic server policy saved');
    $check($updates->instancePolicy()['feed_url']===pbx_updates::serverFeedUrl(),'Saved instance input cannot redirect release downloads');
    $deny(fn()=>$updates->saveInstance(['mode'=>'required','maintenance_hour'=>'2','maintenance_duration'=>'2']),'Mobile mode not allowed on shared server');
    foreach([['maintenance_hour'=>'24','maintenance_duration'=>'2'],['maintenance_hour'=>'0','maintenance_duration'=>'0'],['maintenance_hour'=>[],'maintenance_duration'=>'2']] as $bad)$deny(fn()=>$updates->saveInstance($bad+['mode'=>'automatic']),'Invalid maintenance window rejected');
    $updates->saveTenant($tenants[0],['mode'=>'required']);$updates->saveTenant($tenants[1],['mode'=>'download']);
    $policy=$updates->phonePolicy(['domain_uuid'=>$domains[0]]);
    $check($policy['mode']==='required'&&$policy['feed_url']===pbx_updates::FEED_URL&&count($policy)===5,'Phone receives only its own policy and fixed public feed');
    $check($updates->phonePolicy(['domain_uuid'=>$domains[1]])['mode']==='download','Second tenant policy stays independent');
    $check($updates->phonePolicy(['domain_uuid'=>uuid()])['mode']==='notify','Unassigned standalone PBX defaults optional');
    $check($updates->clientMinimumVersion()==='','Instance Android requirement starts inactive');
    $minimum=pbx_updates::androidVersion();
    $updates->saveClientMinimumVersion(['minimum_version'=>$minimum]);
    if(version_compare(pbx_updates::version(),$minimum,'>'))$deny(fn()=>$updates->saveClientMinimumVersion(['minimum_version'=>pbx_updates::version()]),'A newer server version cannot force an unpublished Android release');
    $check($updates->clientMinimumVersion()===$minimum,'Instance administrator activates release floor');
    $check($updates->instancePolicy()['mode']==='automatic'&&(int)$updates->instancePolicy()['maintenance_hour']===23,'Phone requirement preserves server mode and maintenance window');
    $updates->saveTenant($tenants[0],['mode'=>'notify']);
    foreach($domains as $i=>$domain){
        $p=$updates->phonePolicy(['domain_uuid'=>$domain]);
        $check($p['mode']==='required'&&$p['minimum_version']===$minimum&&$p['required_by_instance']===true&&$p['tenant_mode']===($i===0?'notify':'download'),'Instance requirement overrides tenant preference without discarding it');
        $check($p['feed_url']===pbx_updates::FEED_URL&&$p['channel']==='stable'&&count($p)===8,'Floor cannot supply another feed or expose instance administrator details');
    }
    $standalone=uuid();$p=$updates->phonePolicy(['domain_uuid'=>$standalone]);
    $check($p['mode']==='required'&&$p['minimum_version']===$minimum&&$p['tenant_mode']==='notify','All unassigned phones receive instance floor');
    $futureUser=uuid();$futureTenant=uuid();$futureDomain=uuid();
    $q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$futureDomain,$futureDomain.'.invalid']);
    $q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,?,true)',[$futureUser,$futureDomain,'future-client-fixture']);
    $q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,?,?,?,?,?,true)',[$futureTenant,'Future fixture','future-updates',$futureDomain,$futureUser,'future@example.invalid']);
    $q("insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,template_name,template_version,service_name,request_uuid,created_by) values(?,?,?,'Test',1,'Test',?,?)",[uuid(),$futureTenant,$futureDomain,uuid(),$futureUser]);
    $p=$updates->phonePolicy(['domain_uuid'=>$futureDomain]);
    $check($p['mode']==='required'&&$p['minimum_version']===$minimum&&$p['tenant_mode']==='notify','Future tenant without a policy row receives instance floor');
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_updates/resources/install.sql'));
    $check($updates->clientMinimumVersion()===$minimum,'Repeated migration retains active requirement');
    try{$q('update v_pbx_update_policies set android_minimum_version=? where scope_key=?',[$minimum,'tenant:'.$tenants[0]]);$check(false,'Tenant row cannot hold global requirement');}catch(PDOException){$check(true,'Database constraint prevents tenant row from holding global requirement');}
    $check($updates->tenantPolicy($tenants[0])['android_minimum_version']==='','Tenant row remains outside global requirement');
    foreach([[],['minimum_version'=>[]],['minimum_version'=>'https://example.invalid'],['minimum_version'=>'1.0.11; unsafe'],['minimum_version'=>'01.0.11'],['minimum_version'=>'99999.99999.99999']] as $bad)$deny(fn()=>$updates->saveClientMinimumVersion($bad),'Malformed or unsupported newer release requirement rejected');
    $updates->saveInstance(['mode'=>'automatic','maintenance_hour'=>'23','maintenance_duration'=>'3']);
    $check($updates->clientMinimumVersion()===$minimum,'Server policy save cannot erase Android floor');
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
    $check($updates->clientMinimumVersion()===$minimum,'Tenant may see public required release');
    $check($updates->phonePolicy(['domain_uuid'=>$domains[0]])['mode']==='required','Tenant notify save cannot weaken instance requirement');
    $deny(fn()=>$updates->saveClientMinimumVersion(['minimum_version'=>'']),'Tenant cannot clear global floor');
    $deny(fn()=>$updates->saveClientMinimumVersion(['minimum_version'=>$minimum]),'Tenant cannot set global floor');
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
    $deny(fn()=>$updates->saveClientMinimumVersion(['minimum_version'=>'']),'Disabled administrator cannot clear floor');
    $_SESSION['user_uuid']=$admin;$updates->instance=true;$_SESSION['authorized']=false;$check(!$updates->canView(),'Unauthenticated session denied');$_SESSION['authorized']=true;
    $_SESSION['authorized']=false;$deny(fn()=>$updates->saveClientMinimumVersion(['minimum_version'=>'']),'Unauthenticated global floor mutation denied');$_SESSION['authorized']=true;
    $updates->saveClientMinimumVersion(['minimum_version'=>'']);
    $check($updates->clientMinimumVersion()==='','Instance administrator can clear requirement');
    $check($updates->phonePolicy(['domain_uuid'=>$domains[0]])['mode']==='notify'&&count($updates->phonePolicy(['domain_uuid'=>$domains[0]]))===5,'Clearing requirement restores original tenant preference and legacy response');
    $check($updates->phonePolicy(['domain_uuid'=>$domains[1]])['mode']==='download','Other tenant preference remains unchanged after clearing');
    $check($updates->phonePolicy(['domain_uuid'=>$standalone])['mode']==='notify','Standalone default restores after clearing floor');
    $check($updates->phonePolicy(['domain_uuid'=>$futureDomain])['mode']==='notify','Future tenant default restores after clearing floor');
    $q("update v_pbx_update_commands set status='completed'");
    for($i=0;$i<18;$i++)$q("insert into v_pbx_update_commands(command_uuid,action,status) values(?,'check','completed')",[uuid()]);
    $deny(fn()=>$updates->request('check'),'Request rate limited');
    $check((int)$q("select count(*) from v_group_permissions where group_name='tenant_admin' and permission_name='pbx_update_instance'")->fetchColumn()===0,'Migration never grants tenant global update permission');
    $offer=['platform'=>'windows-x64','update_required'=>true,'download_ready'=>true,'available_version'=>'1.0.999','installed_version'=>'1.0.20'];
    $offerStatus=static function(array $data) use($q) { $q('update v_pbx_update_status set status_json=? where singleton=1',[json_encode($data)]); };
    $offerStatus($offer);
    $notice=$updates->serverNotice('Windows');
    $check($notice['required']&&$notice['ready']&&$notice['can_install']&&$notice['version']==='1.0.999','Instance administrator receives the required verified Windows notice');
    $check($notice['message']==='Your Windows Server PBX system has a new update 1.0.999 - you must update in order to continue using the service.','Windows notice uses the requested wording');
    $check(!$updates->serverNotice('Linux')['required'],'Windows requirement never affects Debian');
    foreach([['platform'=>'debian13-amd64'],['update_required'=>'true'],['update_required'=>false],['available_version'=>'1.0.20'],['available_version'=>'1.0.0999'],['available_version'=>"1.0.999\n"],['available_version'=>'<script>'],['installed_version'=>null]] as $bad){
        $offerStatus(array_replace($offer,$bad));$check(!$updates->serverNotice('Windows')['required'],'Malformed or obsolete notice refused');
    }
    $offerStatus($offer);
    $_SESSION['user_uuid']=$outsider;$updates->instance=false;
    $notice=$updates->serverNotice('Windows');
    $check($notice['required']&&!$notice['can_install']&&count($notice)===5,'Ordinary signed-in users see only a notice without installation permission or private status');
    $deny(fn()=>$updates->request('install'),'Banner cannot grant an ordinary user shared server installation access');
    $_SESSION['user_uuid']=$users[0];
    $deny(fn()=>$updates->serverNotice('Windows'),'Disabled user cannot view the server notice');
    $_SESSION['user_uuid']=$admin;$_SESSION['authorized']=false;
    $deny(fn()=>$updates->serverNotice('Windows'),'Anonymous users cannot view the notice');
    $_SESSION['authorized']=true;
    echo 'PASS: '.$checks." PostgreSQL update policy, ownership, queue, Windows notice and status checks\n";
} finally { if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade'); }
