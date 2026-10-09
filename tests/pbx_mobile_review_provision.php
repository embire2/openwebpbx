<?php
/** Exercise the real operator provisioning twice in a disposable PostgreSQL schema. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
class event_socket {public static function api($command){return '+OK';}public static function create(){return false;}}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='review_provision_'.bin2hex(random_bytes(6));$private=sys_get_temp_dir().'/'.$schema;mkdir($private,0700);
$checks=0;$assert=static function($ok,$message)use(&$checks){if(!$ok)throw new RuntimeException($message);$checks++;};
$provision=dirname(__DIR__).'/app/pbx_mobile/provision-review.php';$output=$private.'/credentials.json';$argv=[$provision,$output];
try{
 $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
 foreach(['v_domains','v_users','v_pbx_tenants','v_pbx_services','v_groups','v_permissions','v_group_permissions','v_user_groups','v_user_settings','v_pbx_restore','v_extensions','v_voicemails','v_voicemail_messages','v_dialplans','v_gateways'] as $table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
 ob_start();include $provision;ob_end_clean();$state=json_decode(file_get_contents($output),true,64,JSON_THROW_ON_ERROR);
 $assert($state['stage']==='complete'&&(fileperms($output)&0777)===0600,'Private reusable credentials saved');
 $assert($db->query('select count(*) from v_domains')->fetchColumn()==2&&$db->query('select count(*) from v_pbx_services')->fetchColumn()==1,'One separate review tenant service');
 $assert($db->query('select count(*) from v_extensions')->fetchColumn()==2,'Two demo extensions');
 $assert($db->query('select count(*) from v_gateways')->fetchColumn()==0,'No provider created');
 $c=json_decode($db->query('select config from v_pbx_restore')->fetchColumn(),true);
 $assert(!$c['trunks']&&!$c['outbound_rules']&&!$c['inbound_rules'],'No external routes');
 $assert($c['users']['7002']['profiles']['Away']['away']['Internal']['all']['type']==='VoiceMail'&&$c['users']['7002']['profiles']['Away']['away']['Internal']['all']['number']==='7001','Message line points at demo mailbox');
 $assert(array_column($c['contacts'],'phone')===['7000'],'Audio contact supplements users without duplicating the message line');
 $assert($db->query('select permission_name from v_group_permissions')->fetchAll(PDO::FETCH_COLUMN)===['pbx_mobile_review'],'Only review permission granted');
 $assert($db->query('select count(*) from v_pbx_mobile_reviewers')->fetchColumn()==1,'Fixed reviewer assignment');
 $assert($db->query("select count(*) from v_voicemail_messages where message_length=2 and message_base64 is not null")->fetchColumn()==1,'Playable synthetic voicemail exists');
 $assert($db->query("select count(*) from v_dialplans where dialplan_number='7000' and domain_uuid is not null")->fetchColumn()==1,'Echo remains tenant-specific');
 $assert($db->query("select count(*) from v_dialplans where dialplan_order=90 and dialplan_xml like '%CALL_REJECTED%' and domain_uuid is not null")->fetchColumn()==1,'Other numbers stop before shared defaults');
 $before=hash('sha256',file_get_contents($output));ob_start();include $provision;ob_end_clean();
 $assert(hash_equals($before,hash('sha256',file_get_contents($output)))&&$db->query('select count(*) from v_extensions')->fetchColumn()==2,'Repeat preserves credentials and objects');
 echo 'PASS: '.$checks." isolated reviewer CLI provisioning and repeat checks\n";
}finally{
 if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');
 if(is_file($output)){$state=json_decode(file_get_contents($output),true);if(is_uuid($state['domain']??''))@rmdir(pbx_paths::media().'/'.$state['domain']);unlink($output);}@rmdir($private);
}
