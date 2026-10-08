<?php
/** CLI-only, isolated PostgreSQL schema. No customer credentials or carrier calls. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__).'/resources/require.php';
class mobile_fixture extends pbx_mobile {protected function tlsReady(): bool {return true;}}
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$schema='openweb_mobile_test_'.bin2hex(random_bytes(6));$count=0;
$q=function($sql,$p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return $s;};
$check=function($ok,$message)use(&$count){if(!$ok)throw new RuntimeException($message);$count++;};
$reject=function(callable $f,$message)use($check){try{$f();}catch(InvalidArgumentException|RuntimeException){$check(true,$message);return;}$check(false,$message);};
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_extensions','v_voicemails','v_voicemail_messages','v_pbx_restore','v_pbx_services','v_pbx_tenants'] as $t)$db->exec('create table '.$t.' (like public.'.$t.' including all)');
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_mobile/resources/install.sql'));
    $owner=uuid();$domains=[uuid(),uuid()];$extensions=[uuid(),uuid()];$mailboxes=[uuid(),uuid()];
    foreach($domains as $i=>$d){$realm=$d.'.invalid';$q('insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,true)',[$d,$realm]);$q("insert into v_extensions(extension_uuid,domain_uuid,extension,number_alias,enabled) values(?,?,'test-auth','100',true)",[$extensions[$i],$d]);$q("insert into v_voicemails(voicemail_uuid,domain_uuid,voicemail_id,voicemail_enabled) values(?,?,'100',true)",[$mailboxes[$i],$d]);
        $c=['realm'=>$realm,'users'=>['100'=>['number'=>'100','name'=>'Test User','enabled'=>true,'auth_id'=>'test-auth','extension_uuid'=>$extensions[$i],'voicemail_uuid'=>$mailboxes[$i],'voicemail_enabled'=>true]],'contacts'=>[['first_name'=>'Company','phone'=>'+12025550101','owner'=>''],['first_name'=>'Private foreign','phone'=>'+12025550102','owner'=>'200']]];
        $q("insert into v_pbx_restore(domain_uuid,source_version,config) values(?,'fixture',?::jsonb)",[$d,json_encode($c)]);
    }
    $q("insert into v_users(user_uuid,domain_uuid,username,user_enabled) values(?,?,'mobile-fixture',true)",[$owner,$domains[0]]);
    $_SESSION=['user_uuid'=>$owner,'domain_uuid'=>$domains[0],'domain_name'=>$domains[0].'.invalid','user'=>['domain_uuid'=>$domains[0]]];$mobile=new mobile_fixture($db);
    $first=$mobile->createCode('100');$first=json_decode($first['payload'],true);$check(strlen($first['code'])===64&&$first['type']==='openwebpbx','Opaque QR payload');
    $second=$mobile->createCode('100');$second=json_decode($second['payload'],true);$reject(fn()=>$mobile->enroll(['code'=>$first['code'],'device_name'=>'First'],'test-ip'),'Superseded QR rejected');
    $phone=$mobile->enroll(['code'=>$second['code'],'device_name'=>'Test Android','platform'=>'android'],'test-ip');$check(strlen($phone['token'])===64&&$phone['sip']['username']!==$phone['account']['extension']&&$phone['sip']['media_encryption']==='srtp','Per-device TLS/SRTP credentials');
    $raw=$q('select * from v_pbx_mobile_devices')->fetch(PDO::FETCH_ASSOC);$check(!str_contains(json_encode($raw),$phone['token'])&&!str_contains(json_encode($raw),$phone['sip']['password']),'Tokens and phone passwords not stored in plaintext');
    $reject(fn()=>$mobile->enroll(['code'=>$second['code'],'device_name'=>'Replay'],'test-ip'),'QR replay rejected');
    $account=$mobile->authenticate($phone['token']);$check(!isset($mobile->bootstrap($account)['sip']['password']),'Bootstrap does not expose credentials');
    $check(count($mobile->directory($account)['contacts'])===2,'Only own PBX and permitted contacts');
    $call=['id'=>uuid(),'number'=>'100','direction'=>'outgoing','started_at'=>gmdate('c'),'duration'=>7,'answered'=>true];$mobile->callLog($account,$call);$mobile->callLog($account,$call);$check(count($mobile->calls($account)['calls'])===1&&$mobile->calls($account)['calls'][0]['duration']===7,'Call reports idempotent and visible');
    $reject(fn()=>$mobile->callLog($account,array_merge($call,['id'=>uuid(),'number'=>"100;evil"])), 'Unsafe call number rejected');
    $message=uuid();$foreign=uuid();foreach([[$message,0],[$foreign,1]] as [$id,$i])$q("insert into v_voicemail_messages(voicemail_message_uuid,domain_uuid,voicemail_uuid,created_epoch,message_length,message_status,message_base64) values(?,?,?,extract(epoch from now()),5,'new',?)",[$id,$domains[$i],$mailboxes[$i],base64_encode('RIFF'.pack('V',36).'WAVEfmt '.pack('VvvVVvv',16,1,1,8000,16000,2,16).'data'.pack('V',0))]);
    $check(count($mobile->voicemail($account)['messages'])===1&&!$mobile->voicemail($account)['messages'][0]['read'],'Voicemail belongs to extension');$reject(fn()=>$mobile->voicemailRead($account,$foreign),'Foreign mailbox denied');$reject(fn()=>$mobile->voicemailAudio($account,'../../etc/passwd'),'Audio traversal denied');$audio=$mobile->voicemailAudio($account,$message);$check(isset($audio['data'])&&strlen($audio['data'])===44,'Database voicemail playback');$mobile->voicemailRead($account,$message);$check($mobile->voicemail($account)['messages'][0]['read'],'Voicemail read persists');$mobile->voicemailDelete($account,$message);$check(count($mobile->voicemail($account)['messages'])===0&&$q('select count(*) from v_voicemail_messages')->fetchColumn()==1,'Delete affects only owned message');
    $q('update v_extensions set enabled=false where extension_uuid=?',[$extensions[0]]);$reject(fn()=>$mobile->authenticate($phone['token']),'Disabled extension denied');$q('update v_extensions set enabled=true where extension_uuid=?',[$extensions[0]]);
    $q('update v_domains set domain_enabled=false where domain_uuid=?',[$domains[0]]);$reject(fn()=>$mobile->authenticate($phone['token']),'Disabled PBX denied');$q('update v_domains set domain_enabled=true where domain_uuid=?',[$domains[0]]);
    $q("update v_pbx_mobile_devices set expires_at=now()-interval '1 second' where device_uuid=?",[$account['device_uuid']]);$reject(fn()=>$mobile->authenticate($phone['token']),'Expired phone denied');$q("update v_pbx_mobile_devices set expires_at=now()+interval '1 day' where device_uuid=?",[$account['device_uuid']]);
    $tenant=uuid();$q("insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,'Test','mobile-test',?,?, 'fixture@example.invalid',false)",[$tenant,$domains[0],$owner]);
    $q("insert into v_pbx_services(service_uuid,tenant_uuid,domain_uuid,template_name,template_version,service_name,request_uuid,created_by) values(?,?,?,'Test',1,'Test',?,?)",[uuid(),$tenant,$domains[0],uuid(),$owner]);
    $reject(fn()=>$mobile->authenticate($phone['token']),'Suspended tenant denied');$reject(fn()=>$mobile->createCode('100'),'Suspended tenant cannot enroll');$q('update v_pbx_tenants set enabled=true where tenant_uuid=?',[$tenant]);
    $check($mobile->authenticate($phone['token'])['number']==='100','Reactivated tenant phone retains own identity');
    $_SESSION['domain_uuid']=$domains[1];$other=json_decode($mobile->createCode('100')['payload'],true);$other=$mobile->enroll(['code'=>$other['code'],'device_name'=>'Other PBX'],'other-ip');$otherAccount=$mobile->authenticate($other['token']);
    $check($mobile->calls($otherAccount)['calls']===[]&&count($mobile->voicemail($otherAccount)['messages'])===1,'Matching extension number in another tenant has isolated data');
    $_SESSION['domain_uuid']=$domains[0];$reject(fn()=>$mobile->adminRevoke('100',$otherAccount['device_uuid']),'Foreign device cannot be removed through active user');
    $mobile->adminRevoke('100',$account['device_uuid']);$reject(fn()=>$mobile->authenticate($phone['token']),'Revoked phone denied');
    $expired=json_decode($mobile->createCode('100')['payload'],true);$q("update v_pbx_mobile_enrollments set expires_at=now()-interval '1 second' where code_hash=?",[hash('sha256',$expired['code'])]);$reject(fn()=>$mobile->enroll(['code'=>$expired['code'],'device_name'=>'Expired'],'test-ip'),'Expired setup rejected');
    $mobile->rate('fixture-limit',1,600);$reject(fn()=>$mobile->rate('fixture-limit',1,600),'Rate limiting enforced');
    $check(str_contains(pbx_mobile::qr(json_encode($second)),'<svg'),'Local QR rendering');
    echo 'PASS: '.$count." native mobile enrollment, scope, replay, voicemail and revocation checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
