<?php
/** Real PostgreSQL service-switch regression; explicit disposable-cluster launcher required. */
if (PHP_SAPI !== 'cli' || getenv('OPENWEB_ISOLATED_PG_TEST') !== '1') exit(2);
require dirname(__DIR__).'/resources/require.php';
$port=config::load()->get('database.0.port');
if ($port!==getenv('OPENWEB_TEST_PG_PORT') || !ctype_digit($port) || (int)$port<20000 || config::load()->get('switch.event_socket.port')!=='1') throw new RuntimeException('Disposable PostgreSQL isolation guard failed.');
class switch_fixture_tenants extends pbx_tenants {
    public bool $isPlatform=false;
    protected function allowed(string $permission): bool {return $this->isPlatform && in_array($permission,['pbx_tenant_manage','domain_all'],true);}
}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_switch_test_'.bin2hex(random_bytes(6));$checks=0;$originalSession=$_SESSION??[];
$assert=static function(bool $condition,string $message)use(&$checks):void {if(!$condition)throw new RuntimeException($message);$checks++;};
$q=static function(string $sql,array $values=[])use($db):PDOStatement {$s=$db->prepare($sql);foreach($values as $name=>$value)$s->bindValue(':'.$name,$value,is_bool($value)?PDO::PARAM_BOOL:PDO::PARAM_STR);$s->execute();return $s;};
try {
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_default_settings','v_domain_settings','v_user_settings'] as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_pbx_tenants','v_pbx_services'] as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
    $ids=[];foreach(['platform','home','first','new','foreign-home','foreign-service','owner','foreign-owner','staff','denied','tenant','foreign-tenant','first-service','new-service','foreign-service-id'] as $name)$ids[$name]=uuid();
    foreach(['platform','home','first','foreign-home','foreign-service'] as $name)$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(:id,:name,true)',['id'=>$ids[$name],'name'=>$name.'.switch-fixture.invalid']);
    foreach(['owner'=>'home','foreign-owner'=>'foreign-home','staff'=>'first','denied'=>'platform'] as $user=>$home)$q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(:id,:home,:name,true)',['id'=>$ids[$user],'home'=>$ids[$home],'name'=>$user.'@switch-fixture.invalid']);
    foreach(['tenant'=>['home','owner'],'foreign-tenant'=>['foreign-home','foreign-owner']] as $tenant=>[$home,$owner])$q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email) values(:id,:name,:name,:home,:owner,:email)',['id'=>$ids[$tenant],'name'=>$tenant,'home'=>$ids[$home],'owner'=>$ids[$owner],'email'=>$owner.'@switch-fixture.invalid']);
    $service=static function(string $id,string $domain,string $tenant,string $owner)use($q):void {$q("insert into v_pbx_services(service_uuid,domain_uuid,tenant_uuid,template_name,template_version,service_name,request_uuid,created_by) values(:id,:domain,:tenant,'switch fixture',1,'Switch fixture',:request,:owner)",['id'=>$id,'domain'=>$domain,'tenant'=>$tenant,'request'=>uuid(),'owner'=>$owner]);};
    $service($ids['first-service'],$ids['first'],$ids['tenant'],$ids['owner']);$service($ids['foreign-service-id'],$ids['foreign-service'],$ids['foreign-tenant'],$ids['foreign-owner']);
    $stale=domains::all();$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(:id,:name,true)',['id'=>$ids['new'],'name'=>'new.switch-fixture.invalid']);$service($ids['new-service'],$ids['new'],$ids['tenant'],$ids['owner']);
    $q("insert into v_domain_settings(domain_setting_uuid,domain_uuid,domain_setting_category,domain_setting_subcategory,domain_setting_name,domain_setting_value,domain_setting_enabled) values(:id,:domain,'domain','time_zone','text','Pacific/Auckland','true')",['id'=>uuid(),'domain'=>$ids['new']]);
    $app=new switch_fixture_tenants($db);$_SERVER['HTTP_HOST']='platform.switch-fixture.invalid';
    $ownerSession=static function(bool $username=false)use($ids,$stale):array {$session=['authorized'=>true,'user_uuid'=>$ids['owner'],'domain_uuid'=>$ids['home'],'domain_name'=>'home.switch-fixture.invalid','context'=>'home.switch-fixture.invalid','user'=>['domain_uuid'=>$ids['home']],'domains'=>$stale,'extension_array'=>['stale'],'menu'=>['stale'],'unrelated_marker'=>'preserve'];if($username)$session['username']='owner@switch-fixture.invalid';return $session;};
    foreach([false,true] as $username) {
        $_SESSION=$ownerSession($username);$assert(!isset($_SESSION['domains'][$ids['new']]),'The regression baseline is not stale');
        $app->switchService($ids['new-service']);
        $assert(isset($_SESSION['domains'][$ids['new']]),'Newly created service missing from refreshed domain list');
        $assert($_SESSION['domain_uuid']===$ids['new']&&$_SESSION['domain_name']==='new.switch-fixture.invalid'&&$_SESSION['context']==='new.switch-fixture.invalid','Refresh changed the explicitly selected PBX');
        $assert(date_default_timezone_get()==='Pacific/Auckland','Switched settings retained another domain timezone');
        $assert(!isset($_SESSION['previous_domain_uuid'])&&$_SESSION['unrelated_marker']==='preserve','Completed previous-domain cleanup or unrelated session state changed');
        $assert(!isset($_SESSION['extension_array'])&&!isset($_SESSION['menu']),'Old per-domain application cache survived');
        $expected=[$ids['home'],$ids['first'],$ids['new']];$actual=array_keys($_SESSION['domains']);sort($expected);sort($actual);$assert($actual===$expected,'Tenant domain refresh exposed foreign domains');
        $assert(!$app->canDomain($ids['foreign-service'])&&!$app->canDomain($ids['foreign-home']),'Refresh granted a foreign tenant access');
    }
    $reject=static function(string $id,string $label)use($app,$assert):void {$before=$_SESSION;try{$app->switchService($id);}catch(Throwable $error){$assert($_SESSION===$before,$label.' changed session state');return;}throw new RuntimeException($label.' was accepted');};
    $_SESSION=$ownerSession();$reject($ids['foreign-service-id'],'Foreign service');$reject(uuid(),'Unknown service');$reject('not-a-uuid','Malformed service');
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=:id',['id'=>$ids['tenant']]);$reject($ids['new-service'],'Suspended owner');$q('update v_pbx_tenants set enabled=true where tenant_uuid=:id',['id'=>$ids['tenant']]);
    $_SESSION=$ownerSession();$_SESSION['user_uuid']=$ids['staff'];$_SESSION['user']['domain_uuid']=$ids['first'];$_SESSION['domain_uuid']=$ids['first'];$reject($ids['new-service'],'Unassigned staff service');
    $app->switchService($ids['first-service']);$assert(array_keys($_SESSION['domains'])===[$ids['first']],'Staff domain list widened beyond their assigned PBX');
    $_SESSION=$ownerSession();$_SESSION['user_uuid']=$ids['denied'];$_SESSION['user']['domain_uuid']=$ids['platform'];$reject($ids['new-service'],'Unrelated account');
    $app->isPlatform=true;$app->switchService($ids['new-service']);$assert(count($_SESSION['domains'])===6&&isset($_SESSION['domains'][$ids['foreign-service']]),'Platform domain refresh lost established all-domain visibility');
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=:id',['id'=>$ids['foreign-tenant']]);$reject($ids['foreign-service-id'],'Suspended tenant under platform administrator');
    $assert($_SESSION['domain_uuid']===$ids['new']&&$_SESSION['context']==='new.switch-fixture.invalid','Denied platform switch changed its selected service');
    echo 'PASS '.$checks." real PostgreSQL stale-domain refresh/selected-context/tenant isolation/denied-switch checks; no native engine contacted\n";
} finally {
    $_SESSION=$originalSession;if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
}
