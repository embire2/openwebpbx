<?php
/** Guarded profile migration runs only inside an isolated PostgreSQL schema. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require __DIR__.'/../resources/require.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='openweb_phone_auth_'.bin2hex(random_bytes(6));$checks=0;
$check=static function(bool $condition,string $message)use(&$checks){if(!$condition)throw new RuntimeException($message);$checks++;};
$q=static function(string $sql,array $args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return $s;};
try {
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_sip_profiles','v_sip_profile_settings'] as $table)$db->exec('create table '.$table.'(like public.'.$table.' including all)');
    $ids=[];foreach(['internal','internal-ipv6','external','foreign-internal'] as $name){$id=uuid();$ids[$name]=$id;$q('insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_hostname,sip_profile_enabled) values(?,?,?,true)',[$id,$name==='foreign-internal'?'internal':$name,$name==='foreign-internal'?'foreign-host':null]);$q("insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(?,?,'inbound-reg-force-matching-username','true',true)",[uuid(),$id]);}
    $missing=sys_get_temp_dir().'/openweb-missing-directory-'.bin2hex(random_bytes(5));
    try{pbx_phone_auth::configure($db,$missing);throw new RuntimeException('Profile equality changed without the guarded directory.');}catch(RuntimeException $e){$check(str_contains($e->getMessage(),'guarded phone directory'),'Unexpected guard refusal.');}
    $check((int)$q("select count(*) from v_sip_profile_settings where sip_profile_setting_value='true'")->fetchColumn()===4,'Missing directory changed a profile.');
    $scripts=__DIR__.'/../app/switch/resources/scripts';$check(pbx_phone_auth::guarded($scripts),'Candidate directory policy marker/invocation missing.');
    $db->beginTransaction();$check(pbx_phone_auth::configure($db,$scripts)===2,'Wrong profile set changed.');$check($db->inTransaction(),'Authentication setup committed its caller transaction.');
    $check((int)$q("select count(*) from v_sip_profile_settings where sip_profile_setting_value='false'")->fetchColumn()===2,'Internal phone settings not changed.');
    foreach(['external','foreign-internal'] as $name)$check($q('select sip_profile_setting_value from v_sip_profile_settings where sip_profile_uuid=?',[$ids[$name]])->fetchColumn()==='true','An unrelated profile was changed.');
    $db->rollBack();$check((int)$q("select count(*) from v_sip_profile_settings where sip_profile_setting_value='false'")->fetchColumn()===0,'Caller rollback did not recover authentication.');
    $check(pbx_phone_auth::configure($db,$scripts)===2&&pbx_phone_auth::configure($db,$scripts)===2,'Repeat migration failed.');
    $check((int)$q('select count(*) from v_sip_profile_settings')->fetchColumn()===4,'Repeat migration duplicated settings.');
    echo "PASS: $checks guarded phone-profile scope/idempotence/transaction checks.\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
