<?php
/** Candidate bootstrap SQL, on fresh and 1.0.6-style mobile schemas; no CLI provisioning. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
$root=dirname(__DIR__);$bootstrap=file_get_contents($root.'/packaging/windows/bootstrap.php');
$pattern=<<<'REGEX'
~foreach\(\[([^\]]+)\] as \$file\)\$db->exec\(file_get_contents\(\$web\.'/app/'\.\$file\)\);~
REGEX;
preg_match_all($pattern,$bootstrap,$loops);
$checks=0;$check=static function($ok,$label)use(&$checks){if(!$ok)throw new RuntimeException($label);$checks++;};
$check(count($loops[1])===2,'Candidate fresh-admin and migration schema loops detected');
$mobile=[];foreach($loops[1] as $loop){preg_match_all("~'([^']+)'~",$loop,$paths);$matches=array_values(array_filter($paths[1],fn($path)=>$path==='pbx_mobile/resources/install.sql'));$check(count($matches)===1,'Each candidate bootstrap stage loads the mobile schema');$mobile[]=file_get_contents($root.'/app/'.$matches[0]);}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='mobile_migration_'.bin2hex(random_bytes(6));
$q=static function($sql,$p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_domains','v_users','v_extensions'] as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
 // Fresh installation uses the SQL named by the actual admin-stage bootstrap.
 $db->exec($mobile[1]);$check($q('select to_regclass(?)',[$schema.'.v_pbx_mobile_reviewers'])->fetchColumn()!==null,'Fresh install has review assignment table');
 $check((int)$q('select count(*) from v_pbx_mobile_reviewers')->fetchColumn()===0,'Fresh install creates no review login automatically');
 $domain=uuid();$user=uuid();$extension=uuid();$device=uuid();
 $q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,'migration.invalid',true)",[$domain]);$q("insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,'fixture',true)",[$user,$domain]);$q("insert into v_extensions(extension_uuid,domain_uuid,extension,enabled) values(?,?,'fixture',true)",[$extension,$domain]);
 $q("insert into v_pbx_mobile_devices(device_uuid,domain_uuid,extension_uuid,device_name,platform,token_hash,sip_username,sip_a1_hash,expires_at) values(?,?,?,'Preserved fixture','android',?,?,?,now()+interval '1 day')",[$device,$domain,$extension,bin2hex(random_bytes(32)),'owm-'.bin2hex(random_bytes(16)),bin2hex(random_bytes(16))]);
 $before=$q('select * from v_pbx_mobile_devices')->fetchAll(PDO::FETCH_ASSOC);
 // Version1.0.6 already has phone/device data and no reviewer table.
 $db->exec('drop table v_pbx_mobile_reviewers');$db->exec($mobile[0]);
 $check($q('select to_regclass(?)',[$schema.'.v_pbx_mobile_reviewers'])->fetchColumn()!==null,'Candidate migration creates reviewer table without operator CLI');
 $check($q('select * from v_pbx_mobile_devices')->fetchAll(PDO::FETCH_ASSOC)===$before,'Existing mobile credentials/metadata preserved');
 $q("insert into v_pbx_mobile_reviewers(user_uuid,domain_uuid,extension_uuid,echo_number,voicemail_number) values(?,?,?,'7000','7002')",[$user,$domain,$extension]);$assignment=$q('select * from v_pbx_mobile_reviewers')->fetchAll(PDO::FETCH_ASSOC);
 $db->exec($mobile[0]);$db->exec($mobile[1]);$check($q('select * from v_pbx_mobile_reviewers')->fetchAll(PDO::FETCH_ASSOC)===$assignment,'Repeated bootstrap stages preserve review assignment');
 $q('delete from v_users where user_uuid=?',[$user]);$check((int)$q('select count(*) from v_pbx_mobile_reviewers')->fetchColumn()===0,'Deleting assigned account removes its reviewer grant');
 echo 'PASS: '.$checks." candidate fresh/upgrade mobile SQL and preservation checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
