<?php
/** Actual callback concurrency/ledger checks. Explicit disposable PostgreSQL DSN only. */
if(PHP_SAPI!=='cli'||!getenv('OPENWEB_CMB_TEST_DSN'))exit(2);
$db=new PDO(getenv('OPENWEB_CMB_TEST_DSN'),getenv('OPENWEB_CMB_TEST_USER')?:'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
function ident(): string{$v=bin2hex(random_bytes(16));return substr($v,0,8).'-'.substr($v,8,4).'-'.substr($v,12,4).'-'.substr($v,16,4).'-'.substr($v,20);}
$schema='cmb_runtime_'.bin2hex(random_bytes(6));$checks=0;
$q=function($sql,$p=[])use($db){$s=$db->prepare($sql);$s->execute($p);return$s;};
$ok=function($v,$message)use(&$checks){if(!$v)throw new RuntimeException($message);$checks++;};
try{
 $db->exec('create schema '.$schema.';set search_path to '.$schema);
 $db->exec('create table v_domains(domain_uuid uuid primary key,domain_enabled boolean default true);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(domain_uuid uuid,tenant_uuid uuid)');$db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/call_me_back.sql'));
 $d=ident();$foreign=ident();$s=ident();$fs=ident();$a=ident();$fa=ident();$proof=hash('sha256','fictional-private-keyed-proof');$cli='+27820000001';
 $q('insert into v_domains(domain_uuid) values(?),(?)',[$d,$foreign]);
 foreach([[$s,$d],[$fs,$foreign]]as[$sid,$did])$q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,prompt_state,prompt_sha256,enabled) values(?,?,'Fictional tenant',?,'1000','ready',repeat('a',64),true)",[$sid,$did,ident()]);
 foreach([[$a,$d,$s],[$fa,$foreign,$fs]]as[$aid,$did,$sid])$q("insert into v_pbx_cmb_accounts(account_uuid,domain_uuid,service_uuid,name,id_hmac,id_last4,total_seconds) values(?,?,?,'Fictional account',?,'0000',650)",[$aid,$did,$sid,$proof]);
 $enqueue=function($number=null,$service=null,$domain=null)use($q,$cli,$s,$d){return$q('select * from openweb_cmb_enqueue(?,?,?,?)',[$domain??$d,$service??$s,ident(),$number??$cli])->fetch(PDO::FETCH_ASSOC);};
 foreach(['anonymous','','+449999999999','+27860000000','+27900000000','+2782000000','27820000001','0820000001']as$bad)$ok(!$enqueue($bad),'Invalid or unnormalised CLI accepted by SQL');
 $ok(!$enqueue($cli,$fs),'Wrong tenant service enqueued');
 $r=$enqueue();$ok($r&&!$r['known'],'First request not queued as untrusted');$rid=$r['request_uuid'];
 $ok(!$enqueue(),'Concurrent duplicate caller enqueued');
 $ok((int)$q('select openweb_cmb_authorize(?,?)',[$rid,$proof])->fetchColumn()===0,'Original incoming call authenticated without callback answer');
 $q("update v_pbx_cmb_requests set state='authenticating' where request_uuid=?",[$rid]);
 $ok((int)$q('select openweb_cmb_authorize(?,NULL)',[$rid])->fetchColumn()===0,'Unknown caller bypassed identity');
 $ok((int)$q('select openweb_cmb_authorize(?,?)',[$rid,hash('sha256','wrong')])->fetchColumn()===0,'Wrong identity authenticated');
 $q('update v_pbx_cmb_accounts set enabled=false where account_uuid=?',[$a]);$ok((int)$q('select openweb_cmb_authorize(?,?)',[$rid,$proof])->fetchColumn()===0,'Disabled account authenticated');$q('update v_pbx_cmb_accounts set enabled=true where account_uuid=?',[$a]);
 $ok((int)$q('select openweb_cmb_authorize(?,?)',[$rid,$proof])->fetchColumn()===600,'First quota reservation not capped at ten minutes');
 $row=$q('select * from v_pbx_cmb_accounts where account_uuid=?',[$a])->fetch(PDO::FETCH_ASSOC);$ok($row['reserved_seconds']===600&&$row['used_seconds']===0,'Reservation debited the wrong counters');
 $ok((int)$q('select openweb_cmb_authorize(?,?)',[$rid,$proof])->fetchColumn()===0,'Same request reserved twice');
 $ok((int)$q('select count(*) from v_pbx_cmb_bindings where account_uuid=?',[$a])->fetchColumn()===1,'Verified number was not bound exactly once');
 $other=$enqueue('+27820000002');$q("update v_pbx_cmb_requests set state='authenticating' where request_uuid=?",[$other['request_uuid']]);$ok((int)$q('select openweb_cmb_authorize(?,?)',[$other['request_uuid'],$proof])->fetchColumn()===0,'Second concurrent call reserved same account');
 $q("select openweb_cmb_finish(?,0,'authentication_failed')",[$other['request_uuid']]);
 $q("update v_pbx_cmb_requests set state='connected',connected_at=now() where request_uuid=?",[$rid]);
 $ok($q("select openweb_cmb_finish(?,120,'connected')",[$rid])->fetchColumn(),'Actual two-minute settlement failed');
 $ok(!$q("select openweb_cmb_finish(?,600,'duplicate')",[$rid])->fetchColumn(),'Duplicate completion debited twice');
 $row=$q('select used_seconds,reserved_seconds from v_pbx_cmb_accounts where account_uuid=?',[$a])->fetch(PDO::FETCH_ASSOC);$ok($row===['used_seconds'=>120,'reserved_seconds'=>0],'Unused reservation was not returned exactly');
 $q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where request_uuid=?",[$rid]);$repeat=$enqueue();$ok($repeat['known'],'Existing authenticated caller not recognised');
 $q("update v_pbx_cmb_requests set state='authenticating' where request_uuid=?",[$repeat['request_uuid']]);$ok((int)$q('select openweb_cmb_authorize(?,NULL)',[$repeat['request_uuid']])->fetchColumn()===530,'Partial allowance was not reserved exactly');
 $q("update v_pbx_cmb_requests set state='connected',connected_at=now() where request_uuid=?",[$repeat['request_uuid']]);
 $ok($q("select openweb_cmb_finish(?,1000,'cap')",[$repeat['request_uuid']])->fetchColumn(),'Capped settlement failed');
 $ok((int)$q('select used_seconds from v_pbx_cmb_accounts where account_uuid=?',[$a])->fetchColumn()===650,'Overlong duration overspent quota');
 $q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where request_uuid=?",[$repeat['request_uuid']]);$exhausted=$enqueue();$q("update v_pbx_cmb_requests set state='authenticating' where request_uuid=?",[$exhausted['request_uuid']]);$ok((int)$q('select openweb_cmb_authorize(?,NULL)',[$exhausted['request_uuid']])->fetchColumn()===0,'Exhausted account received minutes');$q("select openweb_cmb_finish(?,0,'exhausted')",[$exhausted['request_uuid']]);
 $q('update v_pbx_cmb_accounts set total_seconds=1250 where account_uuid=?',[$a]);$q("update v_pbx_cmb_bindings set revoked_at=now() where account_uuid=?",[$a]);$q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where request_uuid=?",[$exhausted['request_uuid']]);$revoked=$enqueue();$ok(!$revoked['known'],'Revoked binding still trusted');$q("update v_pbx_cmb_requests set state='authenticating' where request_uuid=?",[$revoked['request_uuid']]);$ok((int)$q('select openweb_cmb_authorize(?,NULL)',[$revoked['request_uuid']])->fetchColumn()===0,'Revoked caller bypassed ID');$ok((int)$q('select openweb_cmb_authorize(?,?)',[$revoked['request_uuid'],$proof])->fetchColumn()===600,'Reauthentication after revocation failed');
 $q("select openweb_cmb_finish(?,null,'interrupted_review_usage')",[$revoked['request_uuid']]);$ok((int)$q('select used_seconds from v_pbx_cmb_accounts where account_uuid=?',[$a])->fetchColumn()===1250,'Uncertain restart silently released billable quota');
 $ok((int)$q('select used_seconds from v_pbx_cmb_accounts where account_uuid=?',[$fa])->fetchColumn()===0,'Foreign tenant usage changed');
 $q('update v_pbx_cmb_services set enabled=false where service_uuid=?',[$s]);$ok(!$enqueue('+27820000009'),'Disabled service accepted a callback');$q('update v_pbx_cmb_services set enabled=true,max_requests_hour=1 where service_uuid=?',[$s]);$ok(!$enqueue('+27820000009'),'Tenant hourly callback limit not enforced');
 // Four concurrent different CLI requests count towards one tenant-wide active limit.
 $q('delete from v_pbx_cmb_requests where domain_uuid=?',[$d]);$q('update v_pbx_cmb_services set max_requests_hour=30 where service_uuid=?',[$s]);
 for($n=1;$n<=4;$n++)$ok((bool)$enqueue('+2782000001'.$n),'Allowed active callback refused');$ok(!$enqueue('+27820000019'),'Tenant active-call bound exceeded');
 $q('delete from v_pbx_cmb_requests where domain_uuid=?',[$d]);
 // Durable failure throttling survives separate incoming calls and restarts.
 for($n=0;$n<3;$n++){$r=$enqueue();$q("select openweb_cmb_finish(?,0,'authentication_failed')",[$r['request_uuid']]);$q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where request_uuid=?",[$r['request_uuid']]);}
 $ok(!$enqueue(),'Repeated identity failures were not throttled');
 echo "PASS: $checks real PostgreSQL callback ownership, reservation, idempotency, throttling, recovery, quota and binding checks\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public;drop schema '.$schema.' cascade');}
