<?php
/** Isolated database/cryptography checks. Run through pbx_onboarding.py, never on a PBX database. */
if(!in_array(PHP_SAPI,['cli','cli-server'],true)||getenv('OPENWEB_ONBOARDING_TEST')!=='1')exit(2);
$dsn=getenv('OPENWEB_ONBOARDING_TEST_DSN');$state=getenv('OPENWEB_ONBOARDING_TEST_STATE');
if(!is_string($dsn)||!preg_match('/^pgsql:host=127\.0\.0\.1;port=[0-9]+;dbname=postgres$/D',$dsn)||!is_string($state)||!str_starts_with($state,'/var/lib/openwebpbx/onboarding-test-'))exit(2);
if(!defined('PROJECT_ROOT'))define('PROJECT_ROOT',dirname(__DIR__));if(PHP_SAPI==='cli')define('OPENWEB_ONBOARDING_WORKER',true);
function uuid(): string {$h=bin2hex(random_bytes(16));return substr($h,0,8).'-'.substr($h,8,4).'-'.substr($h,12,4).'-'.substr($h,16,4).'-'.substr($h,20);}
function is_uuid($v):bool{return is_string($v)&&preg_match('/^[a-f0-9-]{36}$/D',$v);}
class config {public static array $values=[];public static function load():self{return new self;}public function get($k,$d=null){return self::$values[$k]??$d;}}
class pbx_paths {public static string $root;public static function key():string{return self::$root.'/template.key';}public static function host():string{return 'pbx.example.invalid';}public static function state():string{return self::$root;}}
pbx_paths::$root=$state;
require PROJECT_ROOT.'/resources/classes/pbx_tenant_domains.php';require PROJECT_ROOT.'/resources/classes/pbx_tenant_api_domains.php';require PROJECT_ROOT.'/resources/classes/pbx_onboarding.php';
class onboarding_fixture extends pbx_onboarding {
 public static string $pem;public static array $calls=[];public static array $auth=[];
 protected static function authorityPem():string{return self::$pem;}
 protected static function requiredMarkerPath():string{return pbx_paths::state().'/outside-backup-required/onboarding-required';}
 protected function central(string $route,array $body,?string $bearer=null):array {
  self::$calls[]=['route'=>$route,'body'=>$body,'bearer'=>$bearer];
  return match($route){'/registrations'=>['status'=>'verification_required'], '/registrations/verify','/auth/token'=>self::$auth,
   '/onboarding/email/request'=>['status'=>'verification_required'], '/onboarding/email/verify'=>['verified'=>true,'email'=>'owner@example.invalid']};
 }
}
if(getenv('OPENWEB_ONBOARDING_TEST_HTTP')==='1'){
    if(session_status()!==PHP_SESSION_ACTIVE)session_start();
    $database=(object)['db'=>new PDO($dsn,'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION])];
    return;
}
$db=new PDO($dsn,'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$db->exec("create table v_domains(domain_uuid uuid primary key,domain_name text not null unique,domain_enabled boolean not null default true);
 create table v_users(user_uuid uuid primary key,user_enabled boolean not null default true);
 create table v_pbx_tenants(tenant_uuid uuid primary key,tenant_name text not null,slug text not null,owner_user_uuid uuid not null references v_users,enabled boolean not null default true);
 create table v_pbx_services(service_uuid uuid primary key,domain_uuid uuid not null unique references v_domains,tenant_uuid uuid not null references v_pbx_tenants,service_name text not null,created_at timestamptz not null default now());
 create table v_groups(group_uuid uuid primary key,group_name text not null,domain_uuid uuid);
 create table v_user_groups(user_group_uuid uuid primary key,user_uuid uuid not null references v_users,group_uuid uuid not null references v_groups,group_name text not null);");
$db->exec(file_get_contents(PROJECT_ROOT.'/app/pbx_tenant_domains/resources/install.sql'));$db->exec(file_get_contents(PROJECT_ROOT.'/app/pbx_onboarding/resources/install.sql'));
$q=static function(string $sql,array $p=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($p);return $s;};
$checks=0;$assert=static function(bool $ok,string $label)use(&$checks):void{if(!$ok)throw new RuntimeException($label);$checks++;};
$refuse=static function(callable $fn,string $label)use($assert):void{try{$fn();}catch(Throwable){$assert(true,$label);return;}$assert(false,$label);};
$groupAdmin=uuid();$groupTenant=uuid();$groupStaff=uuid();foreach([[$groupAdmin,'superadmin'],[$groupTenant,'tenant_admin'],[$groupStaff,'openweb_staff']]as[$id,$name])$q('insert into v_groups values(?,?,null)',[$id,$name]);
$make=static function(string $name,string $group,string $groupId)use($q):array{$u=uuid();$t=uuid();$d=uuid();$s=uuid();$q('insert into v_users values(?,true)',[$u]);$q('insert into v_domains values(?,?,true)',[$d,$name.'.example.invalid']);$q('insert into v_pbx_tenants values(?,?,?,?,true)',[$t,$name,$name,$u]);$q('insert into v_pbx_services(service_uuid,domain_uuid,tenant_uuid,service_name) values(?,?,?,?)',[$s,$d,$t,'Local '.$name]);$q('insert into v_user_groups values(?,?,?,?)',[uuid(),$u,$groupId,$group]);return ['user'=>$u,'tenant'=>$t,'domain'=>$d,'service'=>$s];};
$a=$make('alpha','superadmin',$groupAdmin);$b=$make('bravo','tenant_admin',$groupTenant);$staff=uuid();$q('insert into v_users values(?,true)',[$staff]);$q('insert into v_user_groups values(?,?,?,?)',[uuid(),$staff,$groupStaff,'openweb_staff']);
$session=static function(string $user,string $domain):void{$_SESSION=['authorized'=>true,'user_uuid'=>$user,'domain_uuid'=>$domain];};$session($a['user'],$a['domain']);
$instance=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);$pub=openssl_pkey_get_details($instance);$der=base64_decode(preg_replace('/-----[^-]+-----|\s+/','',$pub['key']),true);$hash=hash('sha256',$der);
mkdir($state.'/tenant-domains',0700);file_put_contents($state.'/tenant-domains/instance-public.json',json_encode(['schema'=>1,'server_host'=>pbx_paths::host(),'key_hash'=>$hash,'public_key'=>base64_encode($der)]));chmod($state.'/tenant-domains/instance-public.json',0600);
file_put_contents($state.'/template.key',random_bytes(32));chmod($state.'/template.key',0600);
$q('update v_pbx_onboarding_policy set canonical_host=?,instance_key_hash=?',[pbx_paths::host(),$hash]);
$rsa=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_RSA,'private_key_bits'=>3072]);onboarding_fixture::$pem=openssl_pkey_get_details($rsa)['key'];
$remote=uuid();$secret='owta_'.bin2hex(random_bytes(32));$password='Fixture-registration-42';
onboarding_fixture::$auth=['tenant'=>['tenant_uuid'=>$remote,'email'=>'owner@example.invalid','slug'=>'alpha-company'],'access_token'=>$secret,'token_type'=>'Bearer','expires_at'=>gmdate('c',time()+3600)];
$app=new onboarding_fixture($db,$a['service']);
$assert(count($app->services())===2,'Platform administrator cannot select local services');
$assert(onboarding_fixture::allowsDomain($db,$a['domain']),'Legacy instance was gated by the migration');
mkdir($state.'/outside-backup-required',0700);file_put_contents($state.'/outside-backup-required/onboarding-required',"openwebpbx-onboarding-required-v1\n");
$assert(onboarding_fixture::required($db),'Required marker was ignored');$assert(!onboarding_fixture::allowsDomain($db,$a['domain']),'Marker did not refuse an unregistered PBX');unlink($state.'/outside-backup-required/onboarding-required');
config::$values['openweb.onboarding_required']='true';$assert(onboarding_fixture::required($db),'Fresh configuration flag was ignored');config::$values=[];$q('update v_pbx_onboarding_policy set required=true');
$assert(!onboarding_fixture::allowsDomain($db,$a['domain']),'Unregistered PBX passed required policy');
$app->register(['tenant_name'=>'Fixture Company','slug'=>'alpha-company','email'=>'owner@example.invalid','password'=>$password,'accept_terms'=>true]);
$r=$q('select * from v_pbx_onboarding where domain_uuid=?',[$a['domain']])->fetch(PDO::FETCH_ASSOC);$assert($r['state']==='account_pending','Registration did not request email confirmation');$assert(!str_contains(json_encode($r),$password),'Registration password persisted');
$refuse(fn()=>$app->register(['tenant_name'=>'No terms','slug'=>'alpha-company','email'=>'owner@example.invalid','password'=>$password,'accept_terms'=>false]),'Terms bypassed');
$refuse(fn()=>$app->verify(['token'=>'bad','password'=>$password]),'Malformed verification code accepted');
$app->verify(['token'=>str_repeat('a',64),'password'=>$password]);$status=$app->status();$assert($status['account_connected']&&!$status['ready'],'Verification falsely completed local activation');
$r=$q('select * from v_pbx_onboarding where domain_uuid=?',[$a['domain']])->fetch(PDO::FETCH_ASSOC);$assert($r['token_ciphertext']!==''&&!str_contains(json_encode($r),$secret),'Bearer was stored in plaintext');$assert(!str_contains(json_encode($status),$secret),'Bearer exposed in status');
$job=$app->queue(['label'=>'alpha-company']);$assert($job===$app->queue(['label'=>'alpha-company']),'Pending job retry created another request');$assert((int)$q('select count(*) from v_pbx_onboarding_jobs')->fetchColumn()===1,'Pending job was duplicated');
$jobs=$app->workerJobs();$assert(count($jobs)===1&&$jobs[0]['access_token']===$secret&&$jobs[0]['key_hash']===$hash,'Worker did not receive its encrypted account connection');$assert($app->workerJobs()===[],'Worker lease was not respected');
$bindings=['account_tenant_uuid'=>$remote,'local_tenant_uuid'=>$a['tenant'],'domain_uuid'=>$a['domain'],'key_hash'=>$hash,'server_host'=>pbx_paths::host(),'label'=>'alpha-company'];$installation=uuid();
$payload=['schema'=>1,'issuer'=>pbx_onboarding::API,'audience'=>'openwebpbx-installation','installation_uuid'=>$installation]+$bindings+['issued_at'=>gmdate('c',time()-10),'expires_at'=>gmdate('c',time()+365*86400-10),'generation'=>1];
$encode=static fn(string $v):string=>rtrim(strtr(base64_encode($v),'+/','-_'),'=');
$sign=static function(array $p)use($rsa,$encode):array{$raw=json_encode($p,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);openssl_sign($raw,$signature,$rsa,OPENSSL_ALGO_SHA256);return ['key_id'=>pbx_onboarding::KEY_ID,'algorithm'=>'RS256','payload'=>$encode($raw),'signature'=>$encode($signature)];};
$envelope=$sign($payload);$assert(pbx_onboarding::verifyReceipt($envelope,$bindings,onboarding_fixture::$pem)['generation']===1,'Valid authority receipt refused');
foreach(['account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label']as$key){$bad=$payload;$bad[$key]=match($key){'key_hash'=>str_repeat('0',64),'server_host'=>'different.example.invalid','label'=>'different-label',default=>uuid()};$refuse(fn()=>pbx_onboarding::verifyReceipt($sign($bad),$bindings,onboarding_fixture::$pem),'Wrong '.$key.' binding accepted');}
foreach(['key_id','algorithm','payload','signature']as$key){$bad=$envelope;$bad[$key]='invalid';$refuse(fn()=>pbx_onboarding::verifyReceipt($bad,$bindings,onboarding_fixture::$pem),'Invalid envelope '.$key.' accepted');}
$bad=$envelope;$bad['payload'].='=';$refuse(fn()=>pbx_onboarding::verifyReceipt($bad,$bindings,onboarding_fixture::$pem),'Padded payload accepted');
$bad=$payload;$bad['extra']='not-supported';$refuse(fn()=>pbx_onboarding::verifyReceipt($sign($bad),$bindings,onboarding_fixture::$pem),'Extra receipt field accepted');
foreach(['schema'=>2,'issuer'=>'https://different.example.invalid','audience'=>'wrong-audience','generation'=>0,'issued_at'=>gmdate('c',time()+900),'expires_at'=>gmdate('c',time()-1)]as$key=>$value){$bad=$payload;$bad[$key]=$value;$refuse(fn()=>pbx_onboarding::verifyReceipt($sign($bad),$bindings,onboarding_fixture::$pem),'Invalid '.$key.' accepted');}
$bad=$payload;$bad['expires_at']=gmdate('c',time()+367*86400);$refuse(fn()=>pbx_onboarding::verifyReceipt($sign($bad),$bindings,onboarding_fixture::$pem),'Overlong receipt accepted');
$bad=$payload;$bad['issued_at']='2026-02-30T12:00:00+00:00';$refuse(fn()=>pbx_onboarding::verifyReceipt($sign($bad),$bindings,onboarding_fixture::$pem),'Invalid calendar date accepted');
$app->workerRecord(['job_uuid'=>$job,'revision'=>1,'activation'=>$envelope]);$assert((int)$q('select count(*) from v_pbx_tenant_domains')->fetchColumn()===1,'Owned managed address not queued');$assert(!$app->status()['ready'],'A signed receipt alone completed setup');$assert(onboarding_fixture::authorizedDomain($db,$a['domain']),'Valid grant could not start its separate DNS and certificate preparation');
$host='alpha-company.openwebpbx.com';$until=gmdate('c',time()+86400);$q("update v_pbx_tenant_domains set hostname=?,state='ready',server_host=?,key_hash=?,certificate_not_after=? where domain_uuid=?",[$host,pbx_paths::host(),$hash,$until,$a['domain']]);
$assert(!onboarding_fixture::allowsDomain($db,$a['domain']),'Database ready state bypassed transport proof');
$marker=['schema'=>1,'server_host'=>pbx_paths::host(),'key_hash'=>$hash,'aliases'=>[$host=>$until]];file_put_contents($state.'/tenant-domains/ready.json',json_encode($marker));chmod($state.'/tenant-domains/ready.json',0600);
$assert(onboarding_fixture::allowsDomain($db,$a['domain']),'Authorized local HTTPS state refused');$status=$app->status();$assert($status['ready']&&$status['url']==='https://'.$host,'Tenant address did not finish setup');
$marker['key_hash']=str_repeat('f',64);file_put_contents($state.'/tenant-domains/ready.json',json_encode($marker));$assert(!onboarding_fixture::allowsDomain($db,$a['domain']),'Foreign transport identity accepted');$marker['key_hash']=$hash;file_put_contents($state.'/tenant-domains/ready.json',json_encode($marker));
$q("update v_pbx_onboarding set activation='{}',state='ready' where domain_uuid=?",[$a['domain']]);$assert(!$app->status()['ready'],'Stored ready flag bypassed signature');$assert(!str_contains($app->status()['message'],'registration is confirmed'),'Unverified receipt described as confirmed');$q('update v_pbx_onboarding set activation=cast(? as jsonb) where domain_uuid=?',[json_encode($envelope),$a['domain']]);
$refuse(fn()=>$app->queue(['label'=>'new-address']),'Confirmed address could be renamed');
$originalAuth=onboarding_fixture::$auth;onboarding_fixture::$auth['tenant']['tenant_uuid']=uuid();$refuse(fn()=>$app->signIn(['email'=>'other@example.invalid','password'=>'different-password']), 'A different account replaced a bound account');onboarding_fixture::$auth=$originalAuth;
$expired=$payload;$expired['issued_at']=gmdate('c',time()-365*86400);$expired['expires_at']=gmdate('c',time()-60);$q('update v_pbx_onboarding set activation=cast(? as jsonb) where domain_uuid=?',[json_encode($sign($expired)),$a['domain']]);
$renew=$app->queue(['label'=>'alpha-company']);$assert($renew!==$job,'Completed authorization could not be renewed');$new=$payload;$new['generation']=2;$new['issued_at']=gmdate('c');$new['expires_at']=gmdate('c',time()+365*86400);$newEnvelope=$sign($new);$app->workerRecord(['job_uuid'=>$renew,'revision'=>2,'activation'=>$newEnvelope]);
$assert($app->status()['ready'],'Expired grant could not be renewed');$app->workerRecord(['job_uuid'=>$renew,'revision'=>2,'activation'=>array_reverse($newEnvelope,true)]);$assert($app->status()['ready'],'Identical receipt replay depended on JSON key ordering');
$refuse(fn()=>$app->workerRecord(['job_uuid'=>$renew,'revision'=>2,'activation'=>$envelope]),'Generation rollback accepted');
$refuse(fn()=>$app->workerRecord(['job_uuid'=>$renew,'revision'=>1,'activation'=>$envelope]),'Stale worker revision accepted');
$app->workerRecord(['job_uuid'=>$renew,'revision'=>2,'error_category'=>'verified_account_required','retry_seconds'=>60]);$assert($app->status()['needs_email_verification'],'Existing account email confirmation was not offered');
$app->requestEmailCode();$app->verifyAccountEmail(['token'=>str_repeat('b',64),'password'=>'legacy']);$assert(!$app->status()['needs_email_verification'],'Email confirmation did not clear the pending state');
$q('update v_pbx_onboarding set token_expires_at=now()-interval \'1 minute\' where domain_uuid=?',[$a['domain']]);$assert($app->status()['ready'],'Expired API token disabled a still valid signed grant');$refuse(fn()=>$app->queue(['label'=>'alpha-company']),'Expired API token queued new authorization');
$session($b['user'],$b['domain']);$owner=new onboarding_fixture($db,$b['service']);$assert(count($owner->services())===1,'Tenant owner could enumerate another tenant');$foreign=new onboarding_fixture($db,$a['service']);$refuse(fn()=>$foreign->status(),'Tenant owner could inspect another service');$refuse(fn()=>$foreign->signIn(['email'=>'owner@example.invalid','password'=>$password]),'Tenant owner could link another service');
$session($staff,$a['domain']);$assert((new onboarding_fixture($db))->services()===[],'Staff could enumerate setup services');$refuse(fn()=>$app->status(),'Staff could inspect onboarding');
$_SESSION=['authorized'=>false,'user_uuid'=>$a['user'],'domain_uuid'=>$a['domain']];$refuse(fn()=>$app->services(),'Unauthenticated session accepted');
$session($a['user'],$a['domain']);$q('update v_users set user_enabled=false where user_uuid=?',[$a['user']]);$refuse(fn()=>$app->status(),'Disabled owner retained access');$q('update v_users set user_enabled=true where user_uuid=?',[$a['user']]);
$snapshotA=$q('select row_to_json(o)::text from v_pbx_onboarding o where domain_uuid=?',[$a['domain']])->fetchColumn();
$foreignGrant=$payload;$foreignGrant['domain_uuid']=$b['domain'];$refuse(fn()=>$app->workerImport(['service_uuid'=>$b['service'],'activation'=>$sign($foreignGrant)]),'Image import accepted a grant for another local tenant');
$assert((int)$q('select count(*) from v_pbx_onboarding')->fetchColumn()===1,'Rejected import left a partial registration');
$image=$payload;$image['installation_uuid']=uuid();$image['account_tenant_uuid']=uuid();$image['local_tenant_uuid']=$b['tenant'];$image['domain_uuid']=$b['domain'];$image['label']='bravo-company';$imageEnvelope=$sign($image);
$import=$app->workerImport(['service_uuid'=>$b['service'],'activation'=>$imageEnvelope]);$assert($import['registration_confirmed']&&!$import['ready']&&$import['url']===null,'Image receipt falsely claimed trusted local HTTPS');
$assert($snapshotA===$q('select row_to_json(o)::text from v_pbx_onboarding o where domain_uuid=?',[$a['domain']])->fetchColumn(),'Image import modified another domain');
$rowB=$q('select * from v_pbx_onboarding where domain_uuid=?',[$b['domain']])->fetch(PDO::FETCH_ASSOC);$assert($rowB['token_ciphertext']===''&&$rowB['account_tenant_uuid']===$image['account_tenant_uuid'],'Image import required or fabricated a bearer token');
$revisionB=$rowB['revision'];$app->workerImport(['service_uuid'=>$b['service'],'activation'=>array_reverse($imageEnvelope,true)]);$assert($revisionB===$q('select revision from v_pbx_onboarding where domain_uuid=?',[$b['domain']])->fetchColumn(),'Identical image grant import was not idempotent');
$session($b['user'],$b['domain']);$imageStatus=(new onboarding_fixture($db,$b['service']))->status();$assert($imageStatus['registration_confirmed']&&!$imageStatus['needs_sign_in']&&!$imageStatus['can_request_registration'],'Image pairing incorrectly asked for a password or exposed a new bearer operation');
$hostB='bravo-company.openwebpbx.com';$q("update v_pbx_tenant_domains set hostname=?,state='ready',server_host=?,key_hash=?,certificate_not_after=? where domain_uuid=?",[$hostB,pbx_paths::host(),$hash,$until,$b['domain']]);$marker['aliases'][$hostB]=$until;file_put_contents($state.'/tenant-domains/ready.json',json_encode($marker));
$rec=$app->workerReconcile($b['domain']);$assert($rec['checked']===1&&$rec['ready']===1&&$q('select state from v_pbx_onboarding where domain_uuid=?',[$b['domain']])->fetchColumn()==='ready','Native readiness was not persisted after actual local transport verification');
$q("update v_pbx_tenant_domains set certificate_not_after=now()-interval '1 minute' where domain_uuid=?",[$b['domain']]);$app->workerReconcile($b['domain']);$assert($q('select state from v_pbx_onboarding where domain_uuid=?',[$b['domain']])->fetchColumn()==='preparing','Expired tenant certificate retained persisted ready');
$refuse(fn()=>$app->workerImport(['service_uuid'=>$b['service'],'activation'=>$envelope,'key_hash'=>$hash]),'Image import accepted caller-supplied trust identity');
$session($a['user'],$a['domain']);
$db->exec(file_get_contents(PROJECT_ROOT.'/app/pbx_onboarding/resources/install.sql'));$assert(onboarding_fixture::required($db),'Migration reset the fresh-install gate');
$routes=array_column(onboarding_fixture::$calls,'route');$assert(!in_array('/services',$routes,true)&&!in_array('/installations',$routes,true),'Web wizard created a hosted PBX or performed root signing');
$assert(!str_contains(json_encode($app->status()),$secret)&&!str_contains(json_encode($app->status()),$password),'Public setup state leaked account credentials');
$c=$make('charlie','tenant_admin',$groupTenant);file_put_contents($state.'/http-fixture.json',json_encode(['alpha'=>$a,'bravo'=>$b,'charlie'=>$c,'staff'=>['user'=>$staff,'domain'=>$a['domain']]],JSON_THROW_ON_ERROR));file_put_contents($state.'/authority-fixture.public.pem',onboarding_fixture::$pem);
echo json_encode(['schema'=>1,'passed'=>$checks,'central_transport'=>'fixed-client replaced by in-memory fixture; no network','database'=>'independent disposable PostgreSQL','real_tls_dns_or_calling_tested'=>false],JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n";
