<?php
/** Real PG + RSA/P256 tests in a disposable schema. Public proof transport is a bounded seam. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/require.php';
require_once dirname(__DIR__).'/resources/classes/pbx_tenant_api.php';
require_once dirname(__DIR__).'/resources/classes/pbx_installation_authority.php';
$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);$schema='openweb_authority_test_'.bin2hex(random_bytes(6));$count=0;
$ok=function(bool $value,string $message)use(&$count):void{if(!$value)throw new RuntimeException($message);$count++;};
$denied=function(callable $fn,int $status,string $code='')use($ok):void{try{$fn();}catch(pbx_tenant_api_error $e){$ok($e->status===$status,'Unexpected refusal status');if($code!=='')$ok($e->apiCode===$code,'Unexpected refusal category');return;}throw new RuntimeException('Expected authorization refusal');};
$invalid=function(callable $fn)use($ok):void{try{$fn();}catch(InvalidArgumentException){$ok(true,'Invalid installation input refused');return;}throw new RuntimeException('Invalid installation input accepted');};
$q=function(string $sql,array $p=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($p);return $s;};
class tested_installation_authority extends pbx_installation_authority {
    public OpenSSLAsymmetricKey $rsa;public bool $proofAllowed=true;public int $proofCalls=0;
    public array $ownerCodes=[];
    public function __construct(PDO $db){parent::__construct($db);$this->rsa=openssl_pkey_new(['private_key_bits'=>3072,'private_key_type'=>OPENSSL_KEYTYPE_RSA]);}
    protected function publicPem():string{return openssl_pkey_get_details($this->rsa)['key'];}
    protected function signingKey():OpenSSLAsymmetricKey{return $this->rsa;}
    protected function queueOwnerEmail(array $owner,string $token):void{$this->ownerCodes[$owner['user_email']]=$token;parent::queueOwnerEmail($owner,$token);}
    protected function verifySiteProof(array $r):void{$this->proofCalls++;if(!$this->proofAllowed)throw new pbx_tenant_api_error(403,'installation_proof_required','Synthetic public site proof refused.');}
}
class tested_installation_api extends pbx_tenant_api {
    public tested_installation_authority $authority;
    protected function installationAuthority():pbx_installation_authority{return $this->authority;}
}
function authority_test_decode(string $value):string{$decoded=base64_decode(strtr($value,'-_','+/').str_repeat('=',(4-strlen($value)%4)%4),true);if(!is_string($decoded))throw new RuntimeException('Invalid envelope encoding');return $decoded;}
try{
    $db->exec('create schema '.$schema);$db->exec('set search_path to '.$schema.',public');
    foreach(['v_domains','v_users','v_user_groups','v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings','v_email_queue']as$table)$db->exec('create table '.$table.' (like public.'.$table.' including all)');
    foreach(['v_groups','v_group_permissions','v_permissions','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_default_settings']as$table)$db->exec('insert into '.$table.' select * from public.'.$table);
    foreach(['app/tenant_services/resources/install.sql','app/tenant_api/resources/install.sql','app/tenant_api/resources/onboarding.sql']as$file)$db->exec(file_get_contents(dirname(__DIR__).'/'.$file));
    $db->exec(file_get_contents(dirname(__DIR__).'/app/tenant_api/resources/onboarding.sql'));
    $q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,'true')",[uuid(),pbx_paths::host()]);
    $group=$q("select group_uuid from v_groups where group_name='tenant_admin' and domain_uuid is null limit 1")->fetchColumn();
    $accounts=[];$headers=[];
    foreach(['alpha','bravo','unverified']as$slug){
        $domain=uuid();$user=uuid();$tenant=uuid();
        $q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,?,'true')",[$domain,$slug.'.authority.test']);
        $q("insert into v_users(user_uuid,domain_uuid,username,user_email,password,user_enabled) values(?,?,?,?,?,'true')",[$user,$domain,$slug.'@authority.test',$slug.'@authority.test',password_hash('Synthetic-only-password-2026!',PASSWORD_DEFAULT)]);
        $q("insert into v_user_groups(user_group_uuid,domain_uuid,user_uuid,group_uuid,group_name) values(?,?,?,?,'tenant_admin')",[uuid(),$domain,$user,$group]);
        $q('insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,service_limit) values(?,?,?,?,?,?,1)',[$tenant,$slug,$slug,$domain,$user,$slug.'@authority.test']);
        if($slug!=='unverified')$q("insert into v_pbx_api_registrations(registration_uuid,tenant_name,slug,email,password_hash,expires_at,verified_at,tenant_uuid) values(?,?,?,?,'',now(),now(),?)",[uuid(),$slug,$slug,$slug.'@authority.test',$tenant]);
        $secret='owta_'.bin2hex(random_bytes(32));$q("insert into v_pbx_api_tokens(token_uuid,tenant_uuid,user_uuid,token_name,token_hash,expires_at) values(?,?,?,'Synthetic',?,now()+interval '1 day')",[uuid(),$tenant,$user,hash('sha256',$secret)]);
        $accounts[$slug]=['tenant_uuid'=>$tenant,'user_uuid'=>$user];$headers[$slug]=['Authorization'=>'Bearer '.$secret];
    }
    $authority=new tested_installation_authority($db);$api=new tested_installation_api($db,['enabled'=>true]);$api->authority=$authority;
    $key=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'prime256v1']);$pem=openssl_pkey_get_details($key)['key'];
    $encoded=preg_replace('/-----[^-]+-----|\s+/','',$pem);$hash=hash('sha256',base64_decode($encoded));
    $local=uuid();$domain=uuid();$input=['server_host'=>'pbx.owner.example','public_key'=>$encoded,'local_tenant_uuid'=>$local,'domain_uuid'=>$domain,'label'=>'authority-test'];
    $sign=function(array $challenge,?array $changes=null)use($input,$key):array{
        $row=['nonce'=>$challenge['nonce'],'server_host'=>$input['server_host'],'key_hash'=>$challenge['key_hash'],'account_tenant_uuid'=>$challenge['account_tenant_uuid'],'local_tenant_uuid'=>$input['local_tenant_uuid'],'domain_uuid'=>$input['domain_uuid'],'label'=>$input['label']];
        if($changes)$row=array_replace($row,$changes);openssl_sign(pbx_installation_authority::message($row),$signature,$key,OPENSSL_ALGO_SHA256);return ['challenge_uuid'=>$challenge['challenge_uuid'],'signature'=>base64_encode($signature)];
    };
    [$status,$public]=$api->handle('GET','/onboarding/authority',[],[],'192.0.2.30');
    $ok($status===200&&$public['algorithm']==='RS256'&&$public['key_id']==='installation-2026-a','Public authority identity unavailable');
    $ok(!str_contains($public['public_key_pem'],'PRIVATE KEY'),'Authority endpoint exposed private signing material');
    $denied(fn()=>$authority->challenge($accounts['unverified'],$input),403,'verified_account_required');
    $q('update v_users set password=? where user_uuid=?',[password_hash('Legacy26!',PASSWORD_DEFAULT),$accounts['unverified']['user_uuid']]);
    [$status,$mail]=$api->handle('POST','/onboarding/email/request',[],$headers['unverified'],'192.0.2.31');
    $ok($status===202&&$mail['status']==='verification_required','Legacy owner cannot request a confirmation code');
    $code=$authority->ownerCodes['unverified@authority.test'];$verification=$q('select * from v_pbx_installation_email_verifications')->fetch(PDO::FETCH_ASSOC);
    $ok($verification['verification_hash']===hash('sha256',$code)&&!str_contains(json_encode($verification),$code),'Legacy owner confirmation code stored in plaintext');
    $ok((int)$q("select count(*) from v_email_queue where email_status='waiting'")->fetchColumn()===1,'Legacy confirmation bypassed the global mail queue');
    $denied(fn()=>$authority->verifyEmail($accounts['bravo'],['token'=>$code,'password'=>'Legacy26!']),400,'email_verification_invalid');
    $denied(fn()=>$authority->verifyEmail($accounts['unverified'],['token'=>$code,'password'=>'Incorrect26!']),401,'current_password_invalid');
    [$status,$verified]=$api->handle('POST','/onboarding/email/verify',['token'=>$code,'password'=>'Legacy26!'],$headers['unverified'],'192.0.2.31');
    $ok($status===200&&$verified===['verified'=>true,'email'=>'unverified@authority.test'],'Legacy email confirmation failed with its original short password');
    $ok((int)$q('select count(*) from v_pbx_api_registrations where tenant_uuid=?',[$accounts['unverified']['tenant_uuid']])->fetchColumn()===0,'Email confirmation changed legacy tenant signup classification');
    $ok($q('select verification_hash from v_pbx_installation_email_verifications')->fetchColumn()===null,'Confirmed email code was retained');
    $denied(fn()=>$authority->verifyEmail($accounts['unverified'],['token'=>$code,'password'=>'Legacy26!']),400,'email_verification_invalid');
    $ok(count($authority->list($accounts['unverified'])['installations'])===0,'Confirmed legacy account cannot access installation authorization');
    foreach(['https://pbx.owner.example','pbx.owner.example:443','127.0.0.1','pbx.local','x.openwebpbx.com','Example.COM']as$bad)$invalid(fn()=>pbx_installation_authority::serverHost($bad));
    $invalid(fn()=>pbx_installation_authority::publicKey(base64_encode('not a public key')));
    $invalid(fn()=>pbx_installation_authority::publicKey(base64_encode(base64_decode($encoded).'trailing')));
    $p384=openssl_pkey_new(['private_key_type'=>OPENSSL_KEYTYPE_EC,'curve_name'=>'secp384r1']);$wrong=preg_replace('/-----[^-]+-----|\s+/','',openssl_pkey_get_details($p384)['key']);$invalid(fn()=>pbx_installation_authority::publicKey($wrong));
    [$status,$challenge]=$api->handle('POST','/installations/challenge',$input,$headers['alpha'],'192.0.2.30');
    $ok($status===201&&$challenge['key_hash']===$hash,'Challenge key binding incorrect');
    $ok($challenge['proof_body']==="openwebpbx-instance-v1\n".$challenge['nonce']."\n".$hash."\npbx.owner.example\n",'Host proof bytes differ from the registry protocol');
    $ok($challenge['proof_path']==='/.well-known/openwebpbx-instance/'.$challenge['nonce'],'Host proof path incorrect');
    $ok((int)$q('select count(*) from v_pbx_services')->fetchColumn()===0,'External authorization created a hosted PBX');
    $signed=$sign($challenge);
    $denied(fn()=>$authority->authorize($accounts['bravo'],$signed),403,'challenge_expired');
    $bad=$sign($challenge,['domain_uuid'=>uuid()]);$denied(fn()=>$authority->authorize($accounts['alpha'],$bad),403,'invalid_signature');
    $ok($authority->proofCalls===0,'Bad signature reached the public site proof');
    $authority->proofAllowed=false;$denied(fn()=>$authority->authorize($accounts['alpha'],$signed),403,'installation_proof_required');
    $ok((int)$q('select count(*) from v_pbx_installation_authorizations')->fetchColumn()===0,'Refused public site proof produced an authorization');
    $ok($q('select consumed_at from v_pbx_installation_challenges where challenge_uuid=?',[$challenge['challenge_uuid']])->fetchColumn()===null,'Proof refusal consumed the nonce');
    $authority->proofAllowed=true;[$status,$reply]=$api->handle('POST','/installations',$signed,$headers['alpha'],'192.0.2.30');$grant=$reply['activation'];$installation=$reply['installation'];
    $ok($status===201&&$installation['state']==='authorized'&&$installation['generation']===1,'External installation was not authorized');
    $bytes=authority_test_decode($grant['payload']);$payload=json_decode($bytes,true,16,JSON_THROW_ON_ERROR);$signature=authority_test_decode($grant['signature']);
    $ok(openssl_verify($bytes,$signature,$public['public_key_pem'],OPENSSL_ALGO_SHA256)===1,'RSA receipt signature does not authenticate its exact bytes');
    $ok(openssl_verify($bytes.'x',$signature,$public['public_key_pem'],OPENSSL_ALGO_SHA256)!==1,'Modified receipt payload authenticated');
    $keys=['schema','issuer','audience','installation_uuid','account_tenant_uuid','local_tenant_uuid','domain_uuid','key_hash','server_host','label','issued_at','expires_at','generation'];$actual=array_keys($payload);sort($actual);sort($keys);$ok($actual===$keys,'Receipt payload field set differs from the agreed contract');
    $ok($payload['schema']===1&&$payload['issuer']===pbx_installation_authority::ISSUER&&$payload['audience']===pbx_installation_authority::AUDIENCE,'Receipt trust scope incorrect');
    foreach(['account_tenant_uuid'=>$accounts['alpha']['tenant_uuid'],'local_tenant_uuid'=>$local,'domain_uuid'=>$domain,'key_hash'=>$hash,'server_host'=>$input['server_host'],'label'=>$input['label']]as$k=>$v)$ok($payload[$k]===$v,'Receipt has a different '.$k.' binding');
    $seconds=strtotime($payload['expires_at'])-strtotime($payload['issued_at']);$ok($seconds>=365*86400&&$seconds<=366*86400,'Receipt validity is not one year');
    $ok(!str_contains(json_encode($reply),'@')&&!str_contains(json_encode($reply),'PRIVATE KEY'),'Receipt exposed email or private keys');
    $denied(fn()=>$authority->authorize($accounts['alpha'],$signed),403,'challenge_expired');
    $denied(fn()=>$authority->get($accounts['bravo'],$installation['installation_uuid']),404,'not_found');
    $ok($authority->list($accounts['bravo'])===['installations'=>[]],'Another account sees an installation');
    $ok(count($authority->list($accounts['alpha'])['installations'])===1,'Owner installation list incorrect');
    $next=$authority->challenge($accounts['alpha'],$input);$renewal=$authority->authorize($accounts['alpha'],$sign($next));
    $ok($renewal['installation']['installation_uuid']===$installation['installation_uuid']&&$renewal['installation']['generation']===2,'Exact-bound renewal did not reuse identity and advance generation');
    $ok((int)$q('select count(*) from v_pbx_installation_authorizations')->fetchColumn()===1,'Renewal created a duplicate installation');
    $changed=$input;$changed['label']='different-label';$different=$authority->challenge($accounts['alpha'],$changed);
    $denied(fn()=>$authority->authorize($accounts['alpha'],$sign($different,['label'=>$changed['label']])),409,'installation_binding_conflict');
    $foreign=$authority->challenge($accounts['bravo'],$input);$denied(fn()=>$authority->authorize($accounts['bravo'],$sign($foreign)),409,'installation_binding_conflict');
    $expired=$authority->challenge($accounts['alpha'],$input);$q("update v_pbx_installation_challenges set expires_at=now()-interval '1 second' where challenge_uuid=?",[$expired['challenge_uuid']]);$denied(fn()=>$authority->authorize($accounts['alpha'],$sign($expired)),403,'challenge_expired');
    $q("update v_pbx_installation_authorizations set state='revoked' where installation_uuid=?",[$installation['installation_uuid']]);
    $next=$authority->challenge($accounts['alpha'],$input);$denied(fn()=>$authority->authorize($accounts['alpha'],$sign($next)),403,'installation_revoked');
    $ok($authority->get($accounts['alpha'],$installation['installation_uuid'])['activation']===null,'Revoked grant still returned an active receipt');
    $q('update v_users set user_email=? where user_uuid=?',['changed@authority.test',$accounts['alpha']['user_uuid']]);$denied(fn()=>$authority->list($accounts['alpha']),403,'verified_account_required');
    $q('update v_users set user_email=? where user_uuid=?',['alpha@authority.test',$accounts['alpha']['user_uuid']]);
    $q('update v_pbx_tenants set enabled=false where tenant_uuid=?',[$accounts['alpha']['tenant_uuid']]);$denied(fn()=>$authority->list($accounts['alpha']),403,'verified_account_required');
    $ok((int)$q('select count(*) from v_pbx_services')->fetchColumn()===0,'Authority operations created hosted PBX services');
    echo 'PASS: '.$count." actual PG/P256/RSA installation authority controls; no public network/DNS or hosted PBX writes\n";
}finally{if($db->inTransaction())$db->rollBack();$db->exec('set search_path to public');$db->exec('drop schema if exists '.$schema.' cascade');}
