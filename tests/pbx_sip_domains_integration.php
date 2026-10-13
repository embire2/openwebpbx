<?php
/** Owned SIP addresses, tested in a disposable PostgreSQL schema. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require __DIR__.'/../resources/require.php';
class sip_test_tenants extends pbx_tenants {protected function allowed(string $name):bool{return $name==='pbx_service_create';}}
class sip_test_setup extends pbx_setup {protected function allowed(string $name):bool{return $name==='pbx_service_create';}protected function tenantManager():pbx_tenants{return new sip_test_tenants(database::new()->db);}}
class sip_test_domains extends pbx_sip_domains {protected function tenantManager():pbx_tenants{return new sip_test_tenants($this->db);}protected function setupManager():pbx_setup{return new sip_test_setup($this->db);}}
$db=$database->db;$schema='openweb_sip_domains_'.bin2hex(random_bytes(6));$checks=0;
$q=static function(string $sql,array $values=[])use($db){$s=$db->prepare($sql);$s->execute($values);return $s;};
$check=static function(bool $yes,string $message)use(&$checks){if(!$yes)throw new RuntimeException($message);$checks++;};
$reject=static function(callable $call,string $message)use($check){try{$call();}catch(InvalidArgumentException|RuntimeException|LogicException){$check(true,$message);return;}$check(false,$message);};
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings','v_pbx_restore'] as $table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $db->exec(file_get_contents(__DIR__.'/../app/tenant_services/resources/install.sql'));
    $db->exec(file_get_contents(__DIR__.'/../app/pbx_setup/resources/install.sql'));
    $owners=[uuid(),uuid()];$domains=[uuid(),uuid()];$tenants=[uuid(),uuid()];
    foreach($owners as $i=>$owner){
        $q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$domains[$i],'original-'.$i.'.example.invalid']);
        $q('insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,?,true)',[$owner,$domains[$i],'fixture-'.$i]);
        $q('insert into v_pbx_tenants(tenant_uuid,home_domain_uuid,owner_user_uuid,tenant_name,slug,invite_email,enabled,service_limit) values(?,?,?,?,?,?,true,3)',[$tenants[$i],$domains[$i],$owner,'Fixture '.$i,'fixture-'.$i,'fixture-'.$i.'@example.invalid']);
        $q('insert into v_pbx_restore(domain_uuid,source_version,config,report) values(?,?,cast(? as jsonb),\'{}\')',[$domains[$i],'fixture',json_encode(['realm'=>'original-'.$i.'.example.invalid','users'=>[],'trunks'=>['fixture'=>'untouched'],'ring_groups'=>['untouched'],'timezone'=>'UTC'])]);
    }
    $_SESSION=['user_uuid'=>$owners[0],'domain_uuid'=>$domains[0],'permissions'=>['pbx_service_create'=>true],'user'=>['domain_uuid'=>$domains[0]]];
    $manager=new sip_test_domains($db);$before=$q('select config from v_pbx_restore where domain_uuid=?',[$domains[0]])->fetchColumn();
    $check($manager->primary()==='original-0.example.invalid','Original address changed.');
    $check($manager->save(['sip_domain'=>'Phones.Example.Invalid.'])==='phones.example.invalid','Normalized alias differs.');
    $check($manager->save(['sip_domain'=>'phones.example.invalid'])==='phones.example.invalid'&&count($manager->addresses())===1,'Repeat save duplicated alias.');
    $check($manager->primary()==='phones.example.invalid','Primary address not selected.');
    $after=json_decode($q('select config from v_pbx_restore where domain_uuid=?',[$domains[0]])->fetchColumn(),true);$old=json_decode($before,true);unset($after['phone_domain'],$after['sip_domains']);$check($after===$old,'Phone address changed routing, app realm or source settings.');
    $reject(fn()=>$manager->save(['sip_domain'=>'original-1.example.invalid']),'Foreign canonical address accepted.');
    $q('insert into v_pbx_sip_domains(sip_domain,domain_uuid,created_by) values(?,?,?)',['foreign.example.invalid',$domains[1],$owners[1]]);
    $reject(fn()=>$manager->save(['sip_domain'=>'foreign.example.invalid']),'Foreign alias accepted.');
    $reject(fn()=>$manager->disable(['sip_domain'=>'foreign.example.invalid']),'Foreign alias disabled.');
    foreach(['https://phones.invalid','phones.invalid:5061','phones.invalid/a','173.214.174.68',['nested']] as $bad)$reject(fn()=>$manager->save(['sip_domain'=>$bad]),'Malformed phone address accepted.');
    $manager->save(['sip_domain'=>'second.example.invalid']);$manager->save(['sip_domain'=>'third.example.invalid']);
    $reject(fn()=>$manager->save(['sip_domain'=>'fourth.example.invalid']),'Address limit bypassed.');
    $manager->disable(['sip_domain'=>'third.example.invalid']);$check($manager->primary()==='original-0.example.invalid','Disabling selected address left it active.');
    $manager->save(['sip_domain'=>'phones.example.invalid']);$q('update v_pbx_sip_domains set enabled=false where sip_domain=?',['phones.example.invalid']);$check($manager->primary()==='original-0.example.invalid','Stale saved alias was trusted.');
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$tenants[0]]);$reject(fn()=>new sip_test_domains($db),'Suspended tenant received address control.');
    $q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$tenants[0]]);$_SESSION['user_uuid']=$owners[1];$reject(fn()=>new sip_test_domains($db),'Another tenant received active PBX address control.');
    $check(pbx_sip_domain::certificateCovers('office.sip.example.invalid',['*.sip.example.invalid']),'Wildcard did not cover one leaf.');
    $check(!pbx_sip_domain::certificateCovers('other.office.sip.example.invalid',['*.sip.example.invalid'])&&!pbx_sip_domain::certificateCovers('sip.example.invalid',['*.sip.example.invalid']),'Wildcard covered an invalid depth.');
    echo "PASS: $checks owned phone-domain, preservation, lifecycle, isolation and certificate checks.\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
